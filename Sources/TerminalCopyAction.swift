import AppKit
import CmuxGit
import CmuxTerminal

/// What a cmux copy action puts on the clipboard. Shared by the configurable
/// built-in actions (`cmux.copyWorkingDirectory`, `cmux.copyProjectRoot`,
/// `cmux.copyScreen`), their command palette entries, and surface tab bar
/// buttons, so every entrypoint copies the same text.
enum TerminalCopyAction: Sendable, Equatable {
    /// The terminal's current working directory, as the shell last reported it.
    case workingDirectory
    /// The root of the git work tree containing the working directory, or the
    /// working directory itself outside a repository.
    case projectRoot
    /// The terminal's visible viewport text, without scrollback.
    case visibleScreen
}

extension CmuxSurfaceTabBarBuiltInAction {
    /// The copy behavior this built-in runs, or `nil` for non-copy built-ins.
    var terminalCopyAction: TerminalCopyAction? {
        switch self {
        case .copyWorkingDirectory: return .workingDirectory
        case .copyProjectRoot: return .projectRoot
        case .copyScreen: return .visibleScreen
        case .newWorkspace, .newAgentChat, .cloudVM, .newCloudWorkspace, .newCloudMachine,
             .mobileConnect, .newTerminal, .newBrowser, .newSimulator, .splitRight, .splitDown:
            return nil
        }
    }
}

/// Runs a ``TerminalCopyAction`` against one terminal and writes the result to
/// the standard clipboard through the terminal pasteboard service. Nothing is
/// written when there is nothing to copy; the user hears a beep instead.
@MainActor
enum TerminalCopyActionRunner {
    /// Copies the requested text for `panelId` in `workspace`.
    ///
    /// The working directory comes from ``Workspace/resolvedWorkingDirectory(panelId:)``.
    /// Remote paths are copied as text; they are never opened locally.
    ///
    /// - Parameters:
    ///   - action: What to copy.
    ///   - workspace: The workspace that owns the target panel.
    ///   - panelId: The target panel. `nil` uses the workspace's focused panel.
    /// - Returns: `true` when the copy ran or was started (project-root
    ///   resolution finishes asynchronously), `false` when there was nothing to
    ///   copy.
    @discardableResult
    static func run(_ action: TerminalCopyAction, workspace: Workspace?, panelId: UUID? = nil) -> Bool {
        guard let workspace else {
            NSSound.beep()
            return false
        }
        let targetPanelId = panelId ?? workspace.focusedPanelId
        switch action {
        case .workingDirectory:
            return copy(workspace.resolvedWorkingDirectory(panelId: targetPanelId))
        case .projectRoot:
            guard let directory = workspace.resolvedWorkingDirectory(panelId: targetPanelId) else {
                NSSound.beep()
                return false
            }
            // A remote or cloud workspace's directory lives on another host, so
            // a local repository walk would be wrong. Copy the directory itself,
            // the same fallback used outside a repository.
            if workspace.usesRemoteDirectoryProvenance {
                return copy(directory)
            }
            Task { @MainActor in
                let root = await GitMetadataService().workTreeRoot(forDirectory: directory)
                Self.copy(root ?? directory)
            }
            return true
        case .visibleScreen:
            guard let targetPanelId,
                  let terminalPanel = workspace.terminalPanel(for: targetPanelId) else {
                NSSound.beep()
                return false
            }
            let text = TerminalController.shared.readTerminalTextForSnapshot(
                terminalPanel: terminalPanel,
                includeScrollback: false,
                allowVTExport: false
            )
            return copy(text?.visibleScreenClipboardText)
        }
    }

    @discardableResult
    private static func copy(_ text: String?) -> Bool {
        guard GhosttyApp.terminalPasteboard.copyToStandardClipboard(text) else {
            NSSound.beep()
            return false
        }
        return true
    }
}
