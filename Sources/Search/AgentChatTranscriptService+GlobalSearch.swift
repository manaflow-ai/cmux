import CmuxAgentChat
import CmuxMobileHost
import Foundation

extension AgentChatTranscriptService {
    /// The open Claude or Codex session in a pane, as Global Search indexes it.
    ///
    /// Only open sessions count: the registry's live record for the pane,
    /// never an ended one. Only the resolver's `boundedTranscriptPath` is read
    /// (the path the agent's hook recorded, or Claude's own project file for
    /// the session), so this never runs Codex's recursive fallback scan.
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal panel's ID.
    ///   - paneTitle: The title the pane shows.
    /// - Returns: The session to index, or nil for panes without an open
    ///   session or a readable transcript.
    func globalSearchSource(surfaceID: UUID, paneTitle: String) -> AgentSessionSearchSource? {
        guard let record = registry.liveSession(surfaceID: surfaceID.uuidString) else { return nil }
        switch record.agentKind {
        case .claude, .codex:
            break
        case .other:
            return nil
        }
        guard let path = resolver.boundedTranscriptPath(for: record) else { return nil }
        return AgentSessionSearchSource(
            sessionID: record.sessionID,
            agentKind: record.agentKind,
            transcriptPath: path,
            title: Self.globalSearchTitle(
                paneTitle: paneTitle,
                conversationTitle: record.title,
                agentName: record.agentKind.displayName
            ),
            workingDirectory: record.workingDirectory
        )
    }

    /// The name a session's search row shows: the pane title the agent set
    /// (what the tab shows), else the conversation title, else the agent name.
    /// Leading spinner glyphs the agents animate in their titles are dropped.
    nonisolated static func globalSearchTitle(
        paneTitle: String?,
        conversationTitle: String?,
        agentName: String
    ) -> String {
        for candidate in [paneTitle, conversationTitle] {
            guard let candidate else { continue }
            let cleaned = strippingLeadingSpinnerGlyphs(candidate)
            if !cleaned.isEmpty { return cleaned }
        }
        return agentName
    }

    nonisolated private static func strippingLeadingSpinnerGlyphs(_ title: String) -> String {
        var remaining = Substring(title)
        while let first = remaining.first, titleSpinnerGlyphs.contains(first) || first.isWhitespace {
            remaining = remaining.dropFirst()
        }
        return remaining.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Glyphs Claude and Codex cycle through at the start of their titles.
    nonisolated private static let titleSpinnerGlyphs: Set<Character> = [
        "✳", "✶", "✻", "✽", "✢", "✺", "✦", "✧", "∗", "⟢", "◐", "◑", "◒", "◓", "●",
    ]
}
