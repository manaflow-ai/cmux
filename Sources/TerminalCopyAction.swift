import AppKit
import CmuxGit
import CmuxTerminal

/// What a cmux copy action puts on the clipboard. Shared by the configurable
/// built-in actions (`cmux.copyWorkingDirectory`, `cmux.copyProjectRoot`,
/// `cmux.copyScreen`), their command palette entries, and surface tab bar
/// buttons, so every entrypoint copies the same text.
enum TerminalCopyAction: Sendable, Equatable {
    /// The terminal's current working directory, as its shell last reported it.
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

/// The directory a copy action reads for one terminal panel.
struct TerminalCopyDirectoryTarget: Equatable {
    /// The panel's working directory: a local path, or a path on the remote
    /// or cloud host the panel runs on.
    let path: String
    /// Whether `path` is on this Mac, so a local git walk is meaningful.
    let isLocal: Bool
}

extension Workspace {
    /// The terminal a copy action reads for `panelId`, resolved the way
    /// keyboard input is: a remote-tmux window container projects to its
    /// active inner pane, and any other terminal panel is itself. `nil` when
    /// `panelId` is missing or is not a terminal.
    func copyActionTerminal(panelId: UUID?) -> (surfaceID: UUID, panel: TerminalPanel)? {
        guard let panelId else { return nil }
        return terminalInputTarget(forPanelID: panelId)
    }

    /// The directory a copy action targets for `panelId`, or `nil` when
    /// `panelId` is not a terminal in this workspace or its directory is
    /// unknown.
    ///
    /// Uses the same provenance rules as the sidebar
    /// (``effectivePanelDirectory(panelId:localFallback:)``): a remote, cloud,
    /// or remote-tmux pane only yields a directory its host reported, never
    /// this Mac's workspace directory. There is deliberately no fallback to
    /// another panel's or the workspace's directory.
    func copyActionDirectoryTarget(panelId: UUID?) -> TerminalCopyDirectoryTarget? {
        guard let surfaceID = copyActionTerminal(panelId: panelId)?.surfaceID,
              let path = effectivePanelDirectory(panelId: surfaceID) else {
            return nil
        }
        return TerminalCopyDirectoryTarget(
            path: path,
            isLocal: remoteTmuxControlPane(surfaceID: surfaceID) == nil
                && allowsLocalDirectoryFallback(panelId: surfaceID)
        )
    }
}

/// Runs a ``TerminalCopyAction`` against one terminal panel and writes the
/// result to the standard clipboard through the terminal pasteboard service.
/// Nothing is written when there is nothing to copy; the user hears a beep
/// instead.
@MainActor
enum TerminalCopyActionRunner {
    /// Copies the requested text for the terminal `panelId` in `workspace`.
    ///
    /// Callers pass the panel the user acted on: the focused panel for the
    /// palette and shortcuts, the clicked pane's selected tab for a surface
    /// tab bar button. A missing or non-terminal panel beeps rather than
    /// copying some other pane's text.
    ///
    /// - Parameters:
    ///   - action: What to copy.
    ///   - workspace: The workspace that owns the target panel.
    ///   - panelId: The target panel.
    /// - Returns: `true` when the copy ran or was started (project-root
    ///   resolution finishes asynchronously), `false` when there was nothing
    ///   to copy.
    @discardableResult
    static func run(_ action: TerminalCopyAction, workspace: Workspace?, panelId: UUID?) -> Bool {
        guard let workspace, let terminal = workspace.copyActionTerminal(panelId: panelId) else {
            NSSound.beep()
            return false
        }
        switch action {
        case .workingDirectory:
            return copy(workspace.copyActionDirectoryTarget(panelId: panelId)?.path)
        case .projectRoot:
            guard let target = workspace.copyActionDirectoryTarget(panelId: panelId) else {
                NSSound.beep()
                return false
            }
            // A remote or cloud panel's directory lives on another host, so a
            // local repository walk would be wrong. Copy the directory itself,
            // the same fallback used outside a repository.
            guard target.isLocal else {
                return copy(target.path)
            }
            let pasteboard = GhosttyApp.terminalPasteboard
            let startedAt = pasteboard.standardClipboardChangeCount
            Task { @MainActor in
                let root = await GitMetadataService().workTreeRoot(forDirectory: target.path)
                let status = await pasteboard.copyToStandardClipboard(
                    root ?? target.path,
                    ifUnchangedSince: startedAt
                )
                switch status {
                case .written?, .conditionNotMet?:
                    // conditionNotMet: the user copied something newer while
                    // the walk ran. Their copy wins, and that is not an error.
                    break
                default:
                    NSSound.beep()
                }
            }
            return true
        case .visibleScreen:
            let text = TerminalController.shared.readTerminalTextForSnapshot(
                terminalPanel: terminal.panel,
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
