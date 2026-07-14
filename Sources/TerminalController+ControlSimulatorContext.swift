import CmuxControlSocket
import CmuxSimulator
import Foundation

/// The simulator witnesses for ``ControlCommandCoordinator`` plus the
/// worker-lane `simulator.list` body. Every verb re-checks the
/// `simulator.beta.enabled` gate here (the app side), so a toggle takes
/// effect immediately for CLI and socket callers alike.
extension TerminalController: ControlSimulatorContext {
    // MARK: - Workspace resolution

    private enum SimulatorWorkspaceResolution {
        case tabManagerUnavailable
        case notFound
        case found(tabManager: TabManager, workspace: Workspace)
    }

    private func resolveSimulatorWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> SimulatorWorkspaceResolution {
        if let workspaceID {
            if let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
               let workspace = owner.tabs.first(where: { $0.id == workspaceID }) {
                return .found(tabManager: owner, workspace: workspace)
            }
            guard let tabManager = resolveTabManager(routing: routing) else {
                return .tabManagerUnavailable
            }
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
                return .notFound
            }
            return .found(tabManager: tabManager, workspace: workspace)
        }
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let selectedId = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            return .notFound
        }
        return .found(tabManager: tabManager, workspace: workspace)
    }

    // MARK: - Open / close witnesses (main lane)

    func controlSimulatorOpen(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        deviceQuery: String,
        requestedFocus: Bool
    ) -> ControlSimulatorOpenResolution {
        guard SimulatorSurfaceFeature.isEnabled else { return .featureDisabled }
        switch resolveSimulatorWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(let tabManager, let workspace):
            let focus = v2FocusAllowed(requested: requestedFocus)
            if focus {
                v2MaybeFocusWindow(for: tabManager)
                v2MaybeSelectWorkspace(tabManager, workspace: workspace)
            }
            guard let paneId = workspace.bonsplitController.focusedPaneId,
                  let panel = workspace.newSimulatorSurface(
                      deviceQuery: deviceQuery,
                      inPane: paneId,
                      focus: focus
                  ) else {
                return .openFailed
            }
            return .opened(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: workspace.id,
                paneID: workspace.paneId(forPanelId: panel.id)?.id,
                surfaceID: panel.id
            )
        }
    }

    func controlSimulatorClose(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        surfaceID: UUID?
    ) -> ControlSimulatorCloseResolution {
        guard SimulatorSurfaceFeature.isEnabled else { return .featureDisabled }
        switch resolveSimulatorWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .notFound
        case .found(_, let workspace):
            let panels = workspace.simulatorPanels
            let target: SimulatorPanel?
            if let surfaceID {
                target = panels.first(where: { $0.id == surfaceID })
            } else if panels.count > 1 {
                return .ambiguous(count: panels.count)
            } else {
                target = panels.first
            }
            guard let target else { return .surfaceNotFound }
            guard workspace.closePanel(target.id, force: true) else {
                return .surfaceNotFound
            }
            return .closed(workspaceID: workspace.id, surfaceID: target.id)
        }
    }

    // MARK: - simulator.list (worker lane)

    /// `simulator.list` — runs `simctl list devices --json` off the main
    /// actor and replies with the parsed catalog. Registered in
    /// `ControlCommandExecutionPolicy.socketWorkerMethods`.
    nonisolated func v2SimulatorList(id: Any?, params: [String: Any]) -> String {
        _ = params
        guard SimulatorSurfaceFeature.isEnabled else {
            return v2Error(
                id: id,
                code: "feature_disabled",
                message: SimulatorSurfaceFeature.disabledGuidance
            )
        }
        return v2AsyncResultCall(id: id, timeoutSeconds: 30) {
            do {
                let runner = SimctlCommandRunner()
                let output = try await runner.run(["list", "devices", "--json"])
                let catalog = try SimulatorDeviceCatalog(simctlListJSON: output)
                let devices: [[String: Any]] = catalog.sortedForDisplay.map { device in
                    [
                        "udid": device.udid.rawValue,
                        "name": device.name,
                        "state": device.state.displayName,
                        "available": device.isAvailable,
                        "runtime": device.runtimeIdentifier,
                        "runtime_name": device.runtimeDisplayName,
                        "device_type": device.deviceTypeIdentifier ?? NSNull(),
                    ]
                }
                return .ok(["devices": devices])
            } catch {
                return .err(
                    code: "simctl_error",
                    message: String(describing: error),
                    data: nil
                )
            }
        }
    }
}
