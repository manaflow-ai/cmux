public import Foundation

/// A chat that opened without its folder (cx-nn3e.1): acpmux's `_acpmux/chat_open` said the
/// person must pick one (the recorded folder was deleted or moved, or the chat recorded none).
/// The chat opens in its pane; the page shows `reason` above the composer with Choose Folder.
public nonisolated struct AgentPaneFolderNeeded: Sendable, Equatable {
    /// The chat's key in acpmux's chat index (`harness:id`), for the next `chat_open`.
    public var chat: String
    /// acpmux's reason, shown under the localized line.
    public var reason: String

    public init(chat: String, reason: String) {
        self.chat = chat
        self.reason = reason
    }
}

/// What Choose Folder ended with for a chat whose folder is missing.
public nonisolated enum AgentPaneChatFolderResult: Sendable, Equatable {
    /// The chat resumes in this pane, in `cwd`.
    case adopt(AgentPaneAdopt, cwd: String?)
    /// The chat opened somewhere else (a terminal chat, a read-only transcript).
    case opened
    /// The pick is still not usable: acpmux's new reason.
    case needsFolder(String)
    /// The user cancelled the sheet.
    case cancelled
}
