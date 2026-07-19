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
///   (`proc_bsdinfo.e_tdev`) resolved through a mutation-time index of live
///   surfaces. A pane's pty device is fixed for the pane's lifetime and the
///   process's controlling terminal is a live kernel fact, so a unique match
///   is authoritative regardless of where the pane has been moved.
/// - surface → workspace: the same live index, with
///   `AppDelegate.workspaceContainingPanel` as a compatibility fallback for
///   non-terminal panels (issue #5781 pane moves).
///
/// The CLI reaches this through the `agent.resolve_delivery_target` control
/// method; in-app notification delivery reaches it through
/// `agentNotificationDeliveryTarget` so stale-addressed notifications are
/// retargeted rather than dropped or misfiled.
struct AgentDeliveryTargetCandidate: Equatable {
    let workspaceId: UUID
    let surfaceId: UUID
}

/// Mutation-time index for the hook hot path. Surface TTY reports update this
/// map once; pid delivery then touches only surfaces sharing the queried
/// device instead of rebuilding a list from every workspace.
struct AgentDeliveryTTYIndexCore {
    private struct Binding {
        let workspaceId: UUID
        let surfaceId: UUID
        let ttyDevice: Int64
    }

    private var bindingBySurfaceId: [UUID: Binding] = [:]
    private var surfaceIdsByTTYDevice: [Int64: Set<UUID>] = [:]
    private var surfaceIdsByWorkspaceId: [UUID: Set<UUID>] = [:]

    mutating func replaceBindings(
        workspaceId: UUID,
        bindings: [(surfaceId: UUID, ttyDevice: Int64)]
    ) {
        let previous = surfaceIdsByWorkspaceId[workspaceId] ?? []
        for surfaceId in previous {
            removeBinding(surfaceId: surfaceId)
        }
        for binding in bindings {
            setBinding(
                Binding(
                    workspaceId: workspaceId,
                    surfaceId: binding.surfaceId,
                    ttyDevice: binding.ttyDevice
                )
            )
        }
    }

    mutating func removeBinding(surfaceId: UUID) {
        guard let previous = bindingBySurfaceId.removeValue(forKey: surfaceId) else { return }
        Self.remove(
            surfaceId: surfaceId,
            from: &surfaceIdsByTTYDevice,
            key: previous.ttyDevice
        )
        Self.remove(
            surfaceId: surfaceId,
            from: &surfaceIdsByWorkspaceId,
            key: previous.workspaceId
        )
    }

    func candidates(forTTYDevice ttyDevice: Int64) -> [AgentDeliveryTargetCandidate] {
        (surfaceIdsByTTYDevice[ttyDevice] ?? []).compactMap { surfaceId in
            guard let binding = bindingBySurfaceId[surfaceId] else { return nil }
            return AgentDeliveryTargetCandidate(
                workspaceId: binding.workspaceId,
                surfaceId: surfaceId
            )
        }
    }

    func uniqueCandidate(forTTYDevice ttyDevice: Int64) -> AgentDeliveryTargetCandidate? {
        let candidates = candidates(forTTYDevice: ttyDevice)
        guard let first = candidates.first,
              candidates.allSatisfy({ $0 == first }) else {
            return nil
        }
        return first
    }

    func candidate(forSurfaceId surfaceId: UUID) -> AgentDeliveryTargetCandidate? {
        guard let binding = bindingBySurfaceId[surfaceId] else { return nil }
        return AgentDeliveryTargetCandidate(
            workspaceId: binding.workspaceId,
            surfaceId: surfaceId
        )
    }

    private mutating func setBinding(_ binding: Binding) {
        removeBinding(surfaceId: binding.surfaceId)
        bindingBySurfaceId[binding.surfaceId] = binding
        surfaceIdsByTTYDevice[binding.ttyDevice, default: []].insert(binding.surfaceId)
        surfaceIdsByWorkspaceId[binding.workspaceId, default: []].insert(binding.surfaceId)
    }

    private static func remove<Key: Hashable>(
        surfaceId: UUID,
        from index: inout [Key: Set<UUID>],
        key: Key
    ) {
        guard var values = index[key] else { return }
        values.remove(surfaceId)
        if values.isEmpty {
            index.removeValue(forKey: key)
        } else {
            index[key] = values
        }
    }
}

@MainActor
private final class AgentDeliveryTTYIndex {
    private final class WeakWorkspace {
        weak var value: Workspace?

        init(_ value: Workspace) {
            self.value = value
        }
    }

    static let shared = AgentDeliveryTTYIndex()

    private var core = AgentDeliveryTTYIndexCore()
    private var workspacesById: [UUID: WeakWorkspace] = [:]

    func replaceBindings(for workspace: Workspace) {
        pruneReleasedWorkspaces()
        workspacesById[workspace.id] = WeakWorkspace(workspace)
        core.replaceBindings(
            workspaceId: workspace.id,
            bindings: workspace.surfaceTTYDevices.map {
                (surfaceId: $0.key, ttyDevice: $0.value)
            }
        )
    }

    func uniqueCandidate(forTTYDevice ttyDevice: Int64) -> AgentDeliveryTargetCandidate? {
        var valid: [AgentDeliveryTargetCandidate] = []
        for candidate in core.candidates(forTTYDevice: ttyDevice) {
            if isLive(candidate, expectedTTYDevice: ttyDevice) {
                valid.append(candidate)
            } else {
                core.removeBinding(surfaceId: candidate.surfaceId)
            }
        }
        guard let first = valid.first,
              valid.allSatisfy({ $0 == first }) else {
            return nil
        }
        return first
    }

    func candidate(forSurfaceId surfaceId: UUID) -> AgentDeliveryTargetCandidate? {
        guard let candidate = core.candidate(forSurfaceId: surfaceId) else { return nil }
        guard isLive(candidate, expectedTTYDevice: nil) else {
            core.removeBinding(surfaceId: surfaceId)
            return nil
        }
        return candidate
    }

    private func isLive(
        _ candidate: AgentDeliveryTargetCandidate,
        expectedTTYDevice: Int64?
    ) -> Bool {
        guard let workspace = workspacesById[candidate.workspaceId]?.value,
              !workspace.isRemoteWorkspace,
              !workspace.isRemoteTmuxMirror,
              workspace.panels[candidate.surfaceId] != nil,
              workspace.surfaceIdFromPanelId(candidate.surfaceId) != nil,
              !workspace.isRemoteTerminalSurface(candidate.surfaceId) else {
            return false
        }
        if let expectedTTYDevice {
            return workspace.surfaceTTYDevices[candidate.surfaceId] == expectedTTYDevice
        }
        return workspace.surfaceTTYDevices[candidate.surfaceId] != nil
    }

    private func pruneReleasedWorkspaces() {
        let released = workspacesById.compactMap { workspaceId, weakWorkspace in
            weakWorkspace.value == nil ? workspaceId : nil
        }
        for workspaceId in released {
            workspacesById.removeValue(forKey: workspaceId)
            core.replaceBindings(workspaceId: workspaceId, bindings: [])
        }
    }
}

/// Combines the two live pid signals. The kernel controlling TTY is current
/// process identity and therefore corrects an inherited stale surface env.
/// The start-time-keyed process environment remains the nested-PTY fallback
/// when the process has no cmux-owned controlling TTY.
nonisolated func agentDeliveryTargetCombining(
    ttyTarget: AgentDeliveryTargetCandidate?,
    envTarget: AgentDeliveryTargetCandidate?
) -> AgentDeliveryTargetCandidate? {
    guard let ttyTarget else { return envTarget }
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
    /// Reported TTY names and their device-id index share one mutation path so
    /// live agent resolution never stats every surface on the main actor.
    var surfaceTTYNames: [UUID: String] {
        get { surfaceRegistry.surfaceTTYNames }
        set {
            let previous = surfaceRegistry.surfaceTTYNames
            var devices = surfaceRegistry.surfaceTTYDevices.filter { newValue[$0.key] != nil }
            for (panelId, ttyName) in newValue where previous[panelId] != ttyName {
                devices[panelId] = CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: ttyName)
            }
            surfaceRegistry.surfaceTTYNames = newValue
            surfaceRegistry.surfaceTTYDevices = devices
            AgentDeliveryTTYIndex.shared.replaceBindings(for: self)
        }
    }

    /// Cached TTY character-device ids, updated with ``surfaceTTYNames``.
    var surfaceTTYDevices: [UUID: Int64] { surfaceRegistry.surfaceTTYDevices }

    /// Host-local TTY bindings eligible to identify a process running on this
    /// Mac. Remote workspaces and remote terminal surfaces use a different
    /// `/dev` namespace and must never participate in local device matching.
    var localAgentDeliveryTTYDevices: [(surfaceId: UUID, ttyDevice: Int64)] {
        guard !isRemoteWorkspace, !isRemoteTmuxMirror else { return [] }
        return surfaceTTYDevices.compactMap { panelId, device in
            guard panels[panelId] != nil, !isRemoteTerminalSurface(panelId) else { return nil }
            return (panelId, device)
        }
    }
}

@MainActor
extension AppDelegate {
    /// The live pane that owns the given agent process right now: the
    /// process's controlling tty resolved through the live TTY index
    /// (unique-match only), with the exact live process's start-time-keyed
    /// `CMUX_SURFACE_ID` environment re-homed through
    /// `workspaceContainingPanel` as a nested-PTY fallback. The kernel TTY
    /// corrects a stale inherited surface environment when they disagree.
    func liveAgentDeliveryTarget(forAgentPID pid: pid_t) -> AgentDeliveryTargetCandidate? {
        guard let identity = agentLiveProcessIdentity(pid: pid) else { return nil }

        let ttyTarget = identity.ttyDevice.flatMap {
            AgentDeliveryTTYIndex.shared.uniqueCandidate(forTTYDevice: $0)
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
        if let envSurfaceId = processScope?.surfaceID {
            if let indexed = AgentDeliveryTTYIndex.shared.candidate(forSurfaceId: envSurfaceId) {
                envTarget = indexed
            } else if let owner = workspaceContainingPanel(panelId: envSurfaceId) {
                envTarget = AgentDeliveryTargetCandidate(
                    workspaceId: owner.workspace.id,
                    surfaceId: envSurfaceId
                )
            }
        }

        return agentDeliveryTargetCombining(ttyTarget: ttyTarget, envTarget: envTarget)
    }

    /// Delivery-time target for a notification addressed to
    /// (`claimedTabId`, `surfaceId`). A surface-scoped notification follows
    /// the surface to whichever workspace currently owns it; a workspace-only
    /// notification requires the claimed workspace to still exist. Returns nil
    /// when the target is gone (surface closed, workspace closed) — the
    /// notification is undeliverable, matching the previous drop semantics.
    func agentNotificationDeliveryTarget(
        claimedTabId: UUID,
        surfaceId: UUID?
    ) -> (tabId: UUID, surfaceId: UUID?)? {
        guard let surfaceId else {
            let manager = tabManagerFor(tabId: claimedTabId) ?? tabManager
            guard manager?.tabs.contains(where: { $0.id == claimedTabId }) == true else { return nil }
            return (claimedTabId, nil)
        }
        if let indexed = AgentDeliveryTTYIndex.shared.candidate(forSurfaceId: surfaceId) {
            return (indexed.workspaceId, surfaceId)
        }
        guard let owner = workspaceContainingPanel(
            panelId: surfaceId,
            preferredWorkspaceId: claimedTabId
        ) else {
            return nil
        }
        return (owner.workspace.id, surfaceId)
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
    func v2AgentResolveDeliveryTarget(params: [String: Any]) -> V2CallResult {
        let claimedWorkspaceId = v2UUID(params, "workspace_id")
        let claimedSurfaceId = v2UUID(params, "surface_id")
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
            if let target = appDelegate.liveAgentDeliveryTarget(forAgentPID: agentPid) {
                return .ok([
                    "workspace_id": target.workspaceId.uuidString,
                    "surface_id": target.surfaceId.uuidString,
                    "source": "pid",
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
           let ownerWorkspaceId = AgentDeliveryTTYIndex.shared
               .candidate(forSurfaceId: claimedSurfaceId)?.workspaceId {
            return .ok([
                "workspace_id": ownerWorkspaceId.uuidString,
                "surface_id": claimedSurfaceId.uuidString,
                "source": "surface",
            ])
        }
        if let claimedSurfaceId,
           let owner = appDelegate.workspaceContainingPanel(
            panelId: claimedSurfaceId,
            preferredWorkspaceId: claimedWorkspaceId
           ) {
            return .ok([
                "workspace_id": owner.workspace.id.uuidString,
                "surface_id": claimedSurfaceId.uuidString,
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
