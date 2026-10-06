public import Foundation

/// What "Choose Folder…" ended with (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE): the canonical folder the
/// user chose and the daemon saved; nothing (the user cancelled the sheet); or a refusal with its
/// localized text, which the page shows. Never a silent failure.
public nonisolated enum AgentPaneFolderChoice: Equatable, Sendable {
    case chosen(String)
    case cancelled
    case unavailable(String)

    /// The page's error code for ``unavailable(_:)``.
    public static let unavailableCode = "folder.unavailable"

    /// The background service is an older cmux-tui (kept running across an app update) that
    /// cannot save the workspace's agent folder.
    public static var restartServiceMessage: String {
        String(localized: "agentPane.chooseFolder.restartService",
               defaultValue: "Restart cmux's background service to use Choose Folder.", bundle: .module)
    }

    /// Any other refusal or failure to save the folder.
    public static var notSavedMessage: String {
        String(localized: "agentPane.chooseFolder.notSaved", defaultValue: "The folder could not be saved.", bundle: .module)
    }
}
