import CmuxAgentJournal
import CmuxMobileHost
import Foundation

/// The agent a terminal pane's Stop button interrupts, and how.
///
/// Only agents whose interrupt is a single Escape are listed. The button
/// shows only while the pane's journaled lifecycle says one of them is
/// running, the same gate the TextBox uses before sending Escape.
enum AgentTurnInterruptTarget: String, CaseIterable, Equatable, Sendable {
    case claudeCode = "claude_code"
    case codex

    /// Sidebar lifecycle key.
    var statusKey: String { rawValue }

    /// Agent slug that names the hook session store and journal source.
    var hookSource: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Named keys that interrupt the running turn.
    var interruptKeys: [TextBoxTerminalKey] { [.escape] }

    /// The running agent on a pane, or `nil` when none of the supported
    /// agents is running there.
    static func resolve(
        statusKeyedStates: [String: AgentHibernationLifecycleState]
    ) -> AgentTurnInterruptTarget? {
        allCases.first { statusKeyedStates[$0.statusKey] == .running }
    }

    /// The session to settle after an interrupt: the newest hook-store entry
    /// bound to the surface. `nil` when the store has no binding for it.
    func interruptedSession(
        surfaceID: UUID,
        entries: [AgentChatHookSessionStore.Entry]
    ) -> AgentChatHookSessionStore.Entry? {
        let surface = surfaceID.uuidString
        return entries
            .filter { $0.surfaceID?.caseInsensitiveCompare(surface) == .orderedSame }
            .max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
    }

    /// Journal event that ends the interrupted turn, or `nil` when no session
    /// is bound to the surface. The hook store's workspace wins over
    /// `fallbackWorkspaceID` so the event matches the one the hooks journal.
    func interruptDraft(
        surfaceID: UUID,
        fallbackWorkspaceID: UUID,
        entries: [AgentChatHookSessionStore.Entry],
        now: Date = Date()
    ) -> AgentJournalEventDraft? {
        guard let session = interruptedSession(surfaceID: surfaceID, entries: entries) else {
            return nil
        }
        let workspaceID = session.workspaceID.flatMap(UUID.init(uuidString:)) ?? fallbackWorkspaceID
        return .userInterrupt(
            source: hookSource,
            agentKey: statusKey,
            sessionId: session.sessionID,
            workspaceId: workspaceID.uuidString,
            surfaceId: surfaceID.uuidString,
            occurredAt: now
        )
    }
}
