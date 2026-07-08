import Bonsplit
import Foundation

/// Dock pane creation for installed TUI extensions (`DockExtensionsAppHost`
/// calls this when an extension pane is opened from Settings, the command
/// palette, the CLI, or a deep-link install).
extension DockSplitStore {
    /// Creates a Dock tab for an installed TUI-extension pane. Uses the same
    /// login-shell command path as config-seeded dock controls (the command is
    /// a shell string wrapped by `shellStartupScript`, so PATH and toolchains
    /// resolve like the user's terminal, and the pane drops into a shell when
    /// the TUI exits).
    @discardableResult
    func openExtensionPane(
        controlId: String,
        title: String,
        iconSystemName: String,
        shellCommand: String,
        workingDirectory: String,
        environment: [String: String]
    ) -> UUID? {
        ensureLoaded()
        let panel = makeTerminalPanel(
            command: shellCommand,
            useLoginShellWrapper: true,
            workingDirectory: workingDirectory,
            environment: environment,
            controlId: controlId,
            controlTitle: title
        )
        let paneId = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first
        guard let tabId = attachPanelAsTab(
            panel,
            kind: .terminal,
            title: title,
            icon: iconSystemName,
            inPane: paneId,
            tracksTerminalTitle: true
        ) else { return nil }
        recordExplicitPanelCreation()
        if let paneId {
            bonsplitController.focusPane(paneId)
        }
        bonsplitController.selectTab(tabId)
        panel.focus()
        return panel.id
    }
}
