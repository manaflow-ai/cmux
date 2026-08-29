import AppKit
import Darwin
import Foundation

/// Live delivery-target resolution for agent hook events.
///
/// Invariant (https://github.com/manaflow-ai/cmux/issues/7939): an agent that
/// finishes in pane P of workspace W gets its notification, unread ring, and
/// status on exactly P in W. Attribution therefore resolves from LIVE identity
/// at delivery time — the exact live process's controlling terminal and
/// start-time-keyed environment, plus the surface's current workspace — never
/// from a stale tty registry row or a persisted session record alone.
///
/// Two lookups implement this:
/// - pid → surface: the agent process's controlling tty device
///   (`proc_bsdinfo.e_tdev`) matched against every live Ghostty PTY plus fresh
///   runtime TTY reports. A pane's pty device is fixed for the pane's lifetime,
///   and the process's controlling terminal is a live kernel fact, so a unique
///   match is authoritative regardless of where the pane has been moved.
/// - surface → notification owner: `AppDelegate.notificationSurfaceOwner`,
///   which finds the workspace or Dock that CURRENTLY owns the panel (issue
///   #5781 pane moves and Dock transfers).
///
/// The CLI reaches this through the `agent.resolve_delivery_target` control
/// method; in-app notification delivery reaches it through
/// `agentNotificationDeliveryTarget` so stale-addressed notifications are
/// retargeted rather than dropped or misfiled.
struct AgentDeliveryTargetCandidate: Equatable {
    let workspaceId: UUID
    let surfaceId: UUID
}

/// Resolves live pid evidence under the requested trust policy.
///
/// The default combines controlling-TTY and start-time-keyed environment
/// evidence, preserving the delivery-time behavior for nested PTYs. Hook
/// persistence requests ``AgentProcessBindingResolution/controllingTTY``:
/// inherited `CMUX_SURFACE_ID` is the claim being verified there, so it cannot
/// also corroborate itself.
nonisolated func agentDeliveryTargetCombining(
    ttyTarget: AgentDeliveryTargetCandidate?,
    envTarget: AgentDeliveryTargetCandidate?,
    resolution: AgentProcessBindingResolution = .corroborated
) -> AgentDeliveryTargetCandidate? {
    if resolution == .controllingTTY { return ttyTarget }
    guard let ttyTarget else { return envTarget }
    if let envTarget, envTarget.surfaceId != ttyTarget.surfaceId { return nil }
    return ttyTarget
}

/// Pure core of the pid → surface lookup: the unique surface whose pty device
/// matches the process's controlling terminal. Multiple matches (tty device
/// reuse across mirrors) or none refuse to guess.
nonisolated func agentDeliveryTargetMatchingTTYDevice(
    _ ttyDevice: Int64,
    surfaceTTYDevices: [(workspaceId: UUID, surfaceId: UUID, ttyDevice: Int64)]
) -> AgentDeliveryTargetCandidate? {
    let matches = surfaceTTYDevices.filter { $0.ttyDevice == ttyDevice }
    guard let first = matches.first,
          matches.allSatisfy({ $0.workspaceId == first.workspaceId && $0.surfaceId == first.surfaceId }) else {
        return nil
    }
    return AgentDeliveryTargetCandidate(workspaceId: first.workspaceId, surfaceId: first.surfaceId)
}

/// Live identity of a process: its controlling-terminal device
/// (`proc_bsdinfo.e_tdev`) and its start-time-keyed scope cache key. nil when
/// the process is gone.
nonisolated func agentLiveProcessIdentity(pid: pid_t) -> (ttyDevice: Int64?, scopeCacheKey: CmuxTopProcessScopeCacheKey)? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let expectedSize = MemoryLayout<proc_bsdinfo>.stride
    let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
    guard size == expectedSize else { return nil }
    let device = Int64(info.e_tdev)
    return (device > 0 ? device : nil, CmuxTopProcessSnapshot.scopeCacheKey(from: info))
}

@MainActor
extension Workspace {
    /// TTY metadata writes preserve runtime provenance only when the value is
    /// unchanged. Only ``registerReportedSurfaceTTYName(_:panelId:)`` may
    /// establish current-runtime evidence.
    var surfaceTTYNames: [UUID: String] {
        get { surfaceRegistry.surfaceTTYNames }
        set {
            let previous = surfaceRegistry.surfaceTTYNames
            let unchangedPanelIds = Set(newValue.compactMap { panelId, ttyName in
                previous[panelId] == ttyName ? panelId : nil
            })
            surfaceRegistry.surfaceTTYNames = newValue
            surfaceRegistry.surfaceTTYDevices = surfaceRegistry.surfaceTTYDevices.filter {
                unchangedPanelIds.contains($0.key)
            }
            surfaceRegistry.runtimeReportedTTYSurfaceIDs.formIntersection(unchangedPanelIds)
            surfaceRegistry.runtimeReportedTTYSurfaceGenerations =
                surfaceRegistry.runtimeReportedTTYSurfaceGenerations.filter {
                    unchangedPanelIds.contains($0.key)
                }
        }
    }

    /// Cached character-device ids from explicit current-runtime TTY reports.
    var surfaceTTYDevices: [UUID: Int64] { surfaceRegistry.surfaceTTYDevices }

    /// Records an explicit `report_tty` from the current terminal runtime.
    /// This stays distinct from dictionary metadata writes because a restored
    /// runtime can legitimately report the same TTY name as its predecessor.
    func registerReportedSurfaceTTYName(_ ttyName: String, panelId: UUID) {
        surfaceTTYNames[panelId] = ttyName
        guard let terminal = panels[panelId] as? TerminalPanel else {
            invalidateReportedSurfaceTTYRuntime(panelId: panelId)
            return
        }
        surfaceRegistry.surfaceTTYDevices[panelId] = CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: ttyName)
        surfaceRegistry.runtimeReportedTTYSurfaceIDs.insert(panelId)
        surfaceRegistry.runtimeReportedTTYSurfaceGenerations[panelId] =
            terminal.surface.runtimeSurfaceGeneration
    }

    /// Restores display/port-scan metadata without treating the previous
    /// process's PTY as evidence about the newly created terminal runtime.
    /// A subsequent `report_tty`, even with the same name, populates the live
    /// device index through ``surfaceTTYNames``.
    func restorePersistedSurfaceTTYName(_ ttyName: String?, panelId: UUID) {
        surfaceRegistry.surfaceTTYNames[panelId] = ttyName
        invalidateReportedSurfaceTTYRuntime(panelId: panelId)
    }

    /// Discards live-process evidence while preserving display-only TTY metadata.
    func invalidateReportedSurfaceTTYRuntime(panelId: UUID) {
        surfaceRegistry.surfaceTTYDevices.removeValue(forKey: panelId)
        surfaceRegistry.runtimeReportedTTYSurfaceIDs.remove(panelId)
        surfaceRegistry.runtimeReportedTTYSurfaceGenerations.removeValue(forKey: panelId)
    }

    func hasCurrentRuntimeReportedTTY(panelId: UUID, terminal: TerminalPanel) -> Bool {
        surfaceRegistry.runtimeReportedTTYSurfaceIDs.contains(panelId)
            && surfaceRegistry.runtimeReportedTTYSurfaceGenerations[panelId]
                == terminal.surface.runtimeSurfaceGeneration
    }

    func adoptTransferredSurfaceTTYName(from transfer: DetachedSurfaceTransfer) {
        guard let ttyName = transfer.ttyName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            surfaceTTYNames.removeValue(forKey: transfer.panelId)
            return
        }
        if transfer.ttyNameWasReportedByCurrentRuntime,
           let terminal = panels[transfer.panelId] as? TerminalPanel,
           transfer.ttyReportRuntimeSurfaceGeneration ==
            terminal.surface.runtimeSurfaceGeneration {
            registerReportedSurfaceTTYName(ttyName, panelId: transfer.panelId)
        } else {
            restorePersistedSurfaceTTYName(ttyName, panelId: transfer.panelId)
        }
    }

    func restoreTransferredSurfaceTTYRuntimeProofIfNeeded(from transfer: DetachedSurfaceTransfer) {
        guard transfer.ttyNameWasReportedByCurrentRuntime,
              !surfaceRegistry.runtimeReportedTTYSurfaceIDs.contains(transfer.panelId) else {
            return
        }
        adoptTransferredSurfaceTTYName(from: transfer)
    }

    /// Host-local TTY bindings eligible to identify a process running on this
    /// Mac. Remote workspaces and remote terminal surfaces use a different
    /// `/dev` namespace and must never participate in local device matching.
    var localAgentDeliveryTTYDevices: [(surfaceId: UUID, ttyDevice: Int64)] {
        guard !isRemoteWorkspace, !isRemoteTmuxMirror else { return [] }
        return panels.flatMap { panelId, panel -> [(surfaceId: UUID, ttyDevice: Int64)] in
            guard let terminal = panel as? TerminalPanel,
                  !isRemoteTerminalSurface(panelId) else {
                return []
            }
            var devices: [Int64] = []
            if let liveDevice = terminal.surface.controllingTTYDeviceIdentifier {
                devices.append(liveDevice)
            }
            if hasCurrentRuntimeReportedTTY(panelId: panelId, terminal: terminal),
               let reportedDevice = surfaceTTYDevices[panelId],
               !devices.contains(reportedDevice) {
                devices.append(reportedDevice)
            }
            return devices.map { (panelId, $0) }
        }
    }
}

@MainActor
extension DockSplitStore {
    /// Host-local TTY bindings for terminals currently owned by this Dock.
    ///
    /// A surface transfer removes the panel from its Workspace registry, so
    /// live PID attribution must inspect Dock ownership separately. Prefer the
    /// terminal's current Ghostty PTY and include a fresh reported TTY as the
    /// nested-PTY fallback.
    var localAgentDeliveryTTYDevices: [(surfaceId: UUID, ttyDevice: Int64)] {
        panels.flatMap { panelId, panel -> [(surfaceId: UUID, ttyDevice: Int64)] in
            guard let terminal = panel as? TerminalPanel,
                  detachedSurfaceTransfersByPanelId[panelId]?.isRemoteTerminal != true else {
                return []
            }
            var devices: [Int64] = []
            if let liveDevice = terminal.surface.controllingTTYDeviceIdentifier {
                devices.append(liveDevice)
            }
            if let transfer = detachedSurfaceTransfersByPanelId[panelId],
               transfer.ttyNameWasReportedByCurrentRuntime,
               transfer.ttyReportRuntimeSurfaceGeneration
                == terminal.surface.runtimeSurfaceGeneration,
               let reportedDevice = transfer.ttyName.flatMap(
                   CmuxTopProcessSnapshot.deviceIdentifier(forTTYName:)
               ),
               !devices.contains(reportedDevice) {
                devices.append(reportedDevice)
            }
            return devices.map { (panelId, $0) }
        }
    }
}

@MainActor
extension AppDelegate {
    /// The live pane that owns the given agent process right now: the
    /// process's controlling tty matched against every surface's pty device
    /// (unique-match only), with the exact live process's start-time-keyed
    /// `CMUX_SURFACE_ID` environment re-homed through
    /// `notificationSurfaceOwner` as a nested-PTY fallback. Disagreement fails
    /// closed.
    func liveAgentDeliveryTarget(
        forAgentPID pid: pid_t,
        resolution: AgentProcessBindingResolution = .corroborated
    ) -> AgentDeliveryTargetCandidate? {
        guard let identity = agentLiveProcessIdentity(pid: pid) else { return nil }

        var ttyTarget: AgentDeliveryTargetCandidate?
        if let ttyDevice = identity.ttyDevice {
            // Read the lifecycle-cached Ghostty PTY so shell integration is not
            // required; fresh runtime reports remain a nested-PTY fallback.
            ttyTarget = agentDeliveryTargetMatchingTTYDevice(
                ttyDevice,
                surfaceTTYDevices: liveAgentDeliveryTTYBindings()
            )
        }
        if resolution == .controllingTTY {
            return ttyTarget
        }

        let processScope: CmuxTopProcessScope?
        switch CmuxTopProcessSnapshot.cmuxScopeProbe(
            for: Int(pid),
            expectedCacheKey: identity.scopeCacheKey
        ) {
        case .resolved(let scope): processScope = scope
        case .unavailable: processScope = nil
        }
        var envTarget: AgentDeliveryTargetCandidate?
        if let envSurfaceId = processScope?.surfaceID,
           let owner = liveSurfaceOwner(
               surfaceID: envSurfaceId,
               preferredTabID: processScope?.workspaceID
           ) {
            envTarget = AgentDeliveryTargetCandidate(
                workspaceId: owner.tabID,
                surfaceId: owner.surfaceID
            )
        }

        return agentDeliveryTargetCombining(
            ttyTarget: ttyTarget,
            envTarget: envTarget,
            resolution: resolution
        )
    }

    /// Current local terminal ownership across both workspace splits and Docks.
    /// Internal so behavior tests can guard the cross-container ownership
    /// boundary without needing to manufacture a process on Ghostty's PTY.
    func liveAgentDeliveryTTYBindings() -> [(workspaceId: UUID, surfaceId: UUID, ttyDevice: Int64)] {
        var bindings: [(workspaceId: UUID, surfaceId: UUID, ttyDevice: Int64)] = []
        for manager in agentDeliveryTabManagers() {
            for workspace in manager.tabs {
                for binding in workspace.localAgentDeliveryTTYDevices {
                    bindings.append((workspace.id, binding.surfaceId, binding.ttyDevice))
                }
            }
        }
        for dock in DockSplitStore.liveStores {
            for binding in dock.localAgentDeliveryTTYDevices {
                bindings.append((dock.workspaceId, binding.surfaceId, binding.ttyDevice))
            }
        }
        return bindings
    }

    /// Delivery-time target for an agent event addressed to
    /// (`claimedTabId`, `surfaceId`). A surface-scoped event follows the
    /// surface to whichever workspace or Dock currently owns it. A
    /// workspace-only event requires the claimed workspace or window-Dock
    /// owner to still exist. Returns nil when the target is gone (surface,
    /// workspace, or window closed).
    func agentNotificationDeliveryTarget(
        claimedTabId: UUID?,
        surfaceId: UUID?
    ) -> (tabId: UUID, surfaceId: UUID?)? {
        guard let surfaceId else {
            guard let claimedTabId else { return nil }
            if tabManagerForWindowDockOwner(claimedTabId) != nil {
                return (claimedTabId, nil)
            }
            let manager = tabManagerFor(tabId: claimedTabId) ?? tabManager
            guard manager?.tabs.contains(where: { $0.id == claimedTabId }) == true else { return nil }
            return (claimedTabId, nil)
        }
        guard let owner = notificationSurfaceOwner(
            surfaceID: surfaceId,
            preferredTabID: claimedTabId
        ) else {
            return nil
        }
        return (owner.tabID, owner.surfaceID)
    }

    func agentDeliveryTabManagers() -> [TabManager] {
        var managers: [TabManager] = []
        func append(_ manager: TabManager?) {
            guard let manager, !managers.contains(where: { $0 === manager }) else { return }
            managers.append(manager)
        }
        listMainWindowSummaries().forEach { append(tabManagerFor(windowId: $0.windowId)) }
        append(tabManager)
        return managers
    }
}

@MainActor
extension TerminalController {
    /// `agent.resolve_delivery_target` — resolve the live pane/workspace for a
    /// hook event. Probes:
    /// - `{pid}`: the surface that owns the agent process right now
    ///   (`source: "pid"`); refuses to answer instead of guessing.
    /// - `{surface_id, workspace_id?}`: the workspace that currently hosts a
    ///   known surface (`source: "surface"`), re-homing moved panes.
    /// - `{workspace_id}`: existence check only (`source: "workspace"`).
    /// - `{tty_name, tty_resolution: "reported_tty"}`: a relay-authenticated
    ///   remote workspace's unique fresh TTY report (`source: "tty"`).
    func v2AgentResolveDeliveryTarget(params: [String: Any]) -> V2CallResult {
        let claimedWorkspaceId = v2UUID(params, "workspace_id")
        let claimedSurfaceId = v2UUID(params, "surface_id")
        let pidResolution: AgentProcessBindingResolution
        if let rawPIDResolution = params["pid_resolution"] {
            guard let rawPIDResolution = rawPIDResolution as? String,
                  let parsed = AgentProcessBindingResolution(rawValue: rawPIDResolution) else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "agent.deliveryTarget.error.invalidPidResolution",
                        defaultValue: "pid_resolution must be corroborated or controlling_tty"
                    ),
                    data: nil
                )
            }
            pidResolution = parsed
        } else {
            pidResolution = .corroborated
        }
        guard let appDelegate = AppDelegate.shared else {
            return .err(
                code: "unavailable",
                message: String(
                    localized: "agent.deliveryTarget.error.unavailable",
                    defaultValue: "Delivery target resolution is unavailable; retry after cmux finishes starting."
                ),
                data: nil
            )
        }
        if params.keys.contains("tty_name") {
            let ttyResolution = AgentTTYBindingResolution.reportedTTY.rawValue
            guard params["tty_resolution"] as? String == ttyResolution,
                  let ttyName = params["tty_name"] as? String,
                  TerminalCallerTTYResolver.normalizedName(ttyName) != nil,
                  let remoteWorkspaceId = v2UUID(params, "_cmux_remote_workspace_id"),
                  let authenticatedWorkspace = controlTabForSidebarMutation(id: remoteWorkspaceId),
                  authenticatedWorkspace.isRemoteWorkspace,
                  let target = appDelegate.liveRelayAgentDeliveryTarget(
                      authenticatedWorkspaceID: remoteWorkspaceId,
                      ttyName: ttyName
                  ) else {
                return .err(
                    code: "not_found",
                    message: String(
                        localized: "agent.deliveryTarget.error.notFound",
                        defaultValue: "No live delivery target"
                    ),
                    data: nil
                )
            }
            return .ok([
                "workspace_id": target.workspaceId.uuidString,
                "surface_id": target.surfaceId.uuidString,
                "source": "tty",
                "tty_resolution": ttyResolution,
            ])
        }
        if params.keys.contains("pid") {
            // A socket caller controls both the value and its JSON type. Do
            // not coerce fractional/lossy NSNumber values, trap while
            // narrowing, or let an invalid pid fall through to a different
            // surface/workspace claim in the same request.
            guard let pid = v2StrictInt(params, "pid"),
                  pid > 0,
                  let agentPid = pid_t(exactly: pid) else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "agent.deliveryTarget.error.invalidPid",
                        defaultValue: "PID must be a positive integer"
                    ),
                    data: nil
                )
            }
            if let target = appDelegate.liveAgentDeliveryTarget(
                forAgentPID: agentPid,
                resolution: pidResolution
            ) {
                return .ok([
                    "workspace_id": target.workspaceId.uuidString,
                    "surface_id": target.surfaceId.uuidString,
                    "source": "pid",
                    "pid": pid,
                    "pid_resolution": pidResolution.rawValue,
                ])
            }
            return .err(
                code: "not_found",
                message: String(
                    localized: "agent.deliveryTarget.error.notFound",
                    defaultValue: "No live delivery target"
                ),
                data: nil
            )
        }
        if let claimedSurfaceId,
           let owner = appDelegate.liveSurfaceOwner(
               surfaceID: claimedSurfaceId,
               preferredTabID: claimedWorkspaceId
           ) {
            return .ok([
                "workspace_id": owner.tabID.uuidString,
                "surface_id": owner.surfaceID.uuidString,
                "source": "surface",
            ])
        }
        if let claimedWorkspaceId,
           appDelegate.agentNotificationDeliveryTarget(claimedTabId: claimedWorkspaceId, surfaceId: nil) != nil {
            return .ok([
                "workspace_id": claimedWorkspaceId.uuidString,
                "surface_id": NSNull(),
                "source": "workspace",
            ])
        }
        return .err(
            code: "not_found",
            message: String(
                localized: "agent.deliveryTarget.error.notFound",
                defaultValue: "No live delivery target"
            ),
            data: nil
        )
    }
}
