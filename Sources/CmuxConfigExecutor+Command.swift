import AppKit
import Bonsplit

extension CmuxConfigExecutor {
    /// Captures the invoking pane before authorization and shares execution across action surfaces.
    @discardableResult
    static func executeCommand(
        _ command: String,
        target: CmuxConfigTerminalCommandTarget,
        workspace: Workspace,
        pane: PaneID? = nil,
        baseCwd: String,
        confirm: Bool,
        actionID: String,
        configSourcePath: String?,
        globalConfigPath: String,
        displayTitle: String?,
        icon: CmuxButtonIcon?,
        iconSourcePath: String?,
        presentingWindow: NSWindow?,
        onExecuted: (() -> Void)? = nil
    ) -> Bool {
        let panelID: UUID?
        if let pane {
            panelID = workspace.bonsplitController.selectedTab(inPane: pane)
                .flatMap { workspace.panelIdFromSurfaceId($0.id) }
        } else {
            panelID = workspace.focusedPanelId
        }
        let terminal = pane == nil
            ? workspace.focusedTerminalInputTarget()?.panel
            : panelID.flatMap { workspace.terminalPanel(for: $0) }
        if target == .currentTerminal, terminal == nil { return false }
        let directory = panelID.flatMap { workspace.panelDirectories[$0] } ?? baseCwd
        let environment = target == .background
            ? backgroundCommandEnvironment(workspace: workspace, panelID: panelID)
            : [:]
        let runner = workspace.owningTabManager?.backgroundCommandRunner
        if target == .background, runner == nil { return false }

        return prepareShellInputIfAuthorized(
            command,
            confirm: confirm,
            actionID: actionID,
            target: target,
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath,
            displayTitle: displayTitle,
            icon: icon,
            iconSourcePath: iconSourcePath,
            presentingWindow: presentingWindow
        ) { [weak workspace] shellInput in
            switch target {
            case .currentTerminal:
                if let pane { workspace?.bonsplitController.focusPane(pane) }
                terminal?.sendInput(shellInput)
            case .newTabInCurrentPane:
                if let pane {
                    workspace?.bonsplitController.focusPane(pane)
                    _ = workspace?.newTerminalSurface(
                        inPane: pane,
                        focus: true,
                        initialInput: shellInput,
                        inheritWorkingDirectoryFallback: true
                    )
                } else {
                    workspace?.clearSplitZoom()
                    _ = workspace?.newTerminalSurfaceInFocusedPane(focus: true, initialInput: shellInput)
                }
            case .background:
                Task {
                    await runner?.run(command: shellInput, directory: directory, environment: environment)
                }
            }
            onExecuted?()
        }
    }

    private static func backgroundCommandEnvironment(workspace: Workspace, panelID: UUID?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["CMUX_SOCKET", "CMUX_SOCKET_PASSWORD", "CMUX_WINDOW_ID", "CMUX_WORKSPACE_ID",
                    "CMUX_TAB_ID", "CMUX_SURFACE_ID", "CMUX_PANEL_ID"] {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        environment["CMUX_BUNDLE_ID"] = Bundle.main.bundleIdentifier
        environment["CMUX_WORKSPACE_ID"] = workspace.id.uuidString
        environment["CMUX_TAB_ID"] = workspace.id.uuidString
        environment["CMUX_WINDOW_ID"] = workspace.owningTabManager?.windowId?.uuidString
        environment["CMUX_SURFACE_ID"] = panelID?.uuidString
        environment["CMUX_PANEL_ID"] = panelID?.uuidString
        if let cliURL = CLIForwardingLaunchRouter.bundledCLIURL() {
            environment["CMUX_BUNDLED_CLI_PATH"] = cliURL.path
            environment["PATH"] = cliURL.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        }
        return environment
    }
}
