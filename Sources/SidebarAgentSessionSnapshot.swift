import CmuxAgentChat
import Foundation

/// One live coding-agent session shown as a row under its workspace's title
/// in the left sidebar. Carries absolute timestamps only (floored to the
/// minute), so a running agent's tool calls do not change the value every
/// few seconds; the row formats ages against a separately ticked clock.
struct SidebarAgentSessionSnapshot: Equatable, Identifiable {
    enum State: Equatable {
        case running
        case idle
        case needsInput
    }

    /// The pane hosting the session (the registry's `surfaceID`).
    let panelId: UUID
    var id: UUID { panelId }
    let sessionID: String
    /// "Claude", "Codex", ... for the title fallback and accessibility.
    let agentName: String
    /// Claude's own title, else the pane title, else `agentName`; spinner
    /// glyphs stripped.
    let title: String
    /// The last prompt the user typed, single-lined.
    let lastPrompt: String?
    /// When that prompt arrived through a hook (nil for transcript-sourced prompts).
    let lastPromptAt: Date?
    let state: State
    /// The session's last hook or transcript activity, floored to the minute.
    let lastActivityMinute: Date
}

/// Pure projection from registry records to sidebar session snapshots.
struct SidebarAgentSessionSnapshotBuilder {
    /// Claude Code's terminal-title spinner glyphs (`✳ Claude Code`, `◐ …`).
    static let spinnerGlyphs: Set<Character> = ["✳", "✶", "✻", "✽", "✢", "✺", "◐", "◑", "◒", "◓", "●"]

    /// Builds one snapshot per pane that hosts a live Claude or Codex session,
    /// in the given (tab) order. Panes without a live record produce nothing.
    func sessions(
        orderedPanelIds: [UUID],
        liveRecord: (UUID) -> AgentChatSessionRecord?,
        paneTitle: (UUID) -> String?
    ) -> [SidebarAgentSessionSnapshot] {
        orderedPanelIds.compactMap { panelId in
            guard let record = liveRecord(panelId),
                  let state = Self.state(for: record.state) else { return nil }
            switch record.agentKind {
            case .claude, .codex:
                break
            case .other:
                return nil
            }
            let agentName = record.agentKind.displayName
            return SidebarAgentSessionSnapshot(
                panelId: panelId,
                sessionID: record.sessionID,
                agentName: agentName,
                title: Self.resolvedTitle(aiTitle: record.aiTitle, paneTitle: paneTitle(panelId), agentName: agentName),
                lastPrompt: record.lastPrompt,
                lastPromptAt: record.lastPromptAt,
                state: state,
                lastActivityMinute: Self.flooredToMinute(record.lastActivityAt)
            )
        }
    }

    static func resolvedTitle(aiTitle: String?, paneTitle: String?, agentName: String) -> String {
        for candidate in [aiTitle, paneTitle] {
            guard let candidate else { continue }
            let cleaned = strippingSpinnerGlyphs(candidate)
            if !cleaned.isEmpty { return cleaned }
        }
        return agentName
    }

    /// Drops leading spinner glyphs and surrounding whitespace.
    static func strippingSpinnerGlyphs(_ title: String) -> String {
        var scalars = Substring(title)
        while let first = scalars.first, spinnerGlyphs.contains(first) || first.isWhitespace {
            scalars = scalars.dropFirst()
        }
        return scalars.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Maps the registry state to a row state; ended sessions get no row.
    static func state(for state: ChatAgentState) -> SidebarAgentSessionSnapshot.State? {
        switch state {
        case .idle: return .idle
        case .working: return .running
        case .needsInput: return .needsInput
        case .ended: return nil
        }
    }

    static func flooredToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}
