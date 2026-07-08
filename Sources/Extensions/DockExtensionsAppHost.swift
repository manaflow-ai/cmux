import AppKit
import CmuxControlSocket
import CmuxDockExtensions

/// App-side ``DockExtensionsHost``: opens extension panes as regular terminal
/// splits in the active workspace.
@MainActor
final class DockExtensionsAppHost: DockExtensionsHost {
    var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func openExtensionPane(_ request: DockExtensionPaneOpenRequest) -> Bool {
        guard let appDelegate = AppDelegate.shared,
              let context = appDelegate.preferredRegisteredMainWindowContext(
                  preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
              ) else {
            return false
        }
        let startupScript = DockSplitStore.shellStartupScript(
            command: request.shellCommand,
            workingDirectory: request.workingDirectory
        )
        var environment = request.environment
        environment["CMUX_DOCK_CONTROL_ID"] = request.controlId
        environment["CMUX_DOCK_CONTROL_TITLE"] = request.title

        let controller = TerminalController.shared
        return controller.withSocketCommandPolicy(commandKey: "extension.open", isV2: true) {
            let resolution = controller.controlPaneCreate(
                routing: ControlRoutingSelectors(
                    hasWindowIDParam: true,
                    windowID: context.windowId,
                    groupID: nil,
                    workspaceID: context.tabManager.selectedTabId,
                    surfaceID: nil,
                    paneID: nil
                ),
                inputs: ControlPaneCreateInputs(
                    directionRaw: "right",
                    typeRaw: "terminal",
                    urlRaw: nil,
                    workingDirectory: request.workingDirectory,
                    initialCommand: startupScript,
                    tmuxStartCommand: nil,
                    startupEnvironment: environment,
                    requestedSourceSurfaceID: nil,
                    requestedFocus: true,
                    hasInitialDividerPosition: false,
                    initialDividerPositionRaw: nil
                )
            )
            guard case .created(_, let workspaceID, _, let surfaceID, _) = resolution,
                  let workspace = context.tabManager.tabs.first(where: { $0.id == workspaceID }) else {
                return false
            }
            workspace.setPanelCustomTitle(panelId: surfaceID, title: request.title, source: .auto)
            return true
        }
    }

    func activateDockForExtensions() {
        // Compatibility hook for the package host protocol. Extensions no
        // longer require any Dock feature gate after install.
    }
}
