import Foundation

/// Why View Chat Only (`agentChat.view`, `cmux agent view <chat>`) refuses. The chat text is a
/// format argument, never translated.
nonisolated extension RefusalStrings {
    /// Words that name no Claude Code or Codex chat, the families acpmux can show without running.
    public static func notAWatchableChat(_ chat: String) -> String {
        format("handlers.refusal.notAWatchableChat", "%@ is not a Claude Code or Codex chat. Name it as claude-code:<id> or codex:<id>.",
               truncatedLinkText(chat))
    }
}
