import AppKit
@testable import CmuxNextApp
import CmuxNextHistory
import Foundation
import Testing

/// cmux#38186 review: Remove from History and Clear History of an agent row hide it at once in the
/// app's `HiddenHistoryStore` (what `AgentHistory.sessions` filters on), not only after the daemon's
/// `history.hidden` is read again on the next connect, and a load that lands before the daemon applied
/// the mutation does not bring it back. `AgentHistory`'s folds come only from a daemon's journal, so
/// these check the filter `sessions` applies: `hidden.document.hides(qualifiedID, activeAt:, kind: "agent")`.
@MainActor @Suite(.serialized) struct HiddenHistoryLocalHideTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    static let session = AgentSession(machine: "local", provider: "claude", sessionID: "s-1",
                                      startedAt: Date().addingTimeInterval(-120), lastActivityAt: Date().addingTimeInterval(-60))

    static func entry(_ session: AgentSession) -> HistoryEntry {
        HistoryEntry(id: "agent:\(session.qualifiedID)", kind: .agent, time: session.lastActivityAt, title: "Claude",
                     payload: .agent(session))
    }

    static func hidden(_ services: AppServices, _ session: AgentSession) -> Bool {
        services.history.agents.hidden.document.hides(session.qualifiedID, activeAt: session.lastActivityAt, kind: "agent")
    }

    @Test func removedAgentRowIsHiddenAtOnce() {
        let services = Self.services()
        let other = AgentSession(machine: "local", provider: "codex", sessionID: "s-2",
                                 startedAt: Self.session.startedAt, lastActivityAt: Self.session.lastActivityAt)
        #expect(!Self.hidden(services, Self.session))
        services.history.remove(Self.entry(Self.session))
        #expect(Self.hidden(services, Self.session))
        #expect(!Self.hidden(services, other))
    }

    @Test func clearingAgentsForAllTimeHidesThemAtOnce() {
        let services = Self.services()
        services.history.clear(kinds: [.agent], range: .all)
        #expect(Self.hidden(services, Self.session))
        // Activity after the clear shows again.
        let later = AgentSession(machine: "local", provider: "claude", sessionID: "s-3",
                                 startedAt: Date(), lastActivityAt: Date().addingTimeInterval(60))
        #expect(!Self.hidden(services, later))
    }

    @Test func clearingOtherKindsLeavesAgents() {
        let services = Self.services()
        services.history.clear(kinds: [.location], range: .all)
        #expect(!Self.hidden(services, Self.session))
    }

    @Test func loadBeforeTheDaemonAppliedKeepsLocalHides() {
        let services = Self.services()
        services.history.remove(Self.entry(Self.session))
        // The stored document has not caught up yet, but holds another hide of its own.
        var stored = HiddenHistory()
        stored.hide(entry: "local/codex/s-2")
        services.history.agents.hidden.loaded(stored)
        #expect(Self.hidden(services, Self.session))
        #expect(services.history.agents.hidden.document.entries.contains("local/codex/s-2"))
    }

    /// The finding's own case: the session the vault, palette and resume read (`AgentHistory.sessions`) goes at once.
    @Test func aRemovedAgentRowLeavesSessionsAtOnce() throws {
        let services = Self.services()
        var fold = AgentSessionFold(machine: "local")
        let at = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        fold.apply([AgentJournalRecord(sequence: 1, kind: "agent.session.started", occurredAtMs: at, subjects: [], provider: "claude", sessionID: "s-1"),
                    AgentJournalRecord(sequence: 2, kind: "agent.session.started", occurredAtMs: at, subjects: [], provider: "codex", sessionID: "s-2")])
        services.history.agents.folds["local"] = fold
        let shown = try #require(services.history.agents.sessions.first { $0.sessionID == "s-1" })
        services.history.remove(Self.entry(shown))
        #expect(services.history.agents.sessions.map(\.sessionID) == ["s-2"])
        services.history.clear(kinds: [.agent], range: .all)
        #expect(services.history.agents.sessions.isEmpty)
    }
}
