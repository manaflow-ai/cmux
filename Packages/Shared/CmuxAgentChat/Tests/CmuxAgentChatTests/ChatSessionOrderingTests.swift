import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("ChatSessionOrdering")
struct ChatSessionOrderingTests {
    private static let base = Date(timeIntervalSince1970: 1_781_000_000)

    private func session(
        _ id: String,
        _ state: ChatAgentState,
        ago: TimeInterval
    ) -> ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: id,
            agentKind: .claude,
            title: id,
            state: state,
            lastActivityAt: Self.base.addingTimeInterval(-ago)
        )
    }

    @Test("a live session is picked over a more recent ended one")
    func liveBeatsRecentEnded() {
        let result = ChatSessionDescriptor.openable([
            session("ended-new", .ended, ago: 1),
            session("idle-old", .idle, ago: 100),
        ])
        #expect(result.first?.id == "idle-old")
        // The ended session is dropped entirely while a live one exists.
        #expect(result.count == 1)
    }

    @Test("needs-input sorts ahead of working and idle")
    func attentionFirst() {
        let result = ChatSessionDescriptor.openable([
            session("idle", .idle, ago: 1),
            session("working", .working(since: Self.base), ago: 2),
            session("needs", .needsInput(since: Self.base), ago: 50),
        ])
        #expect(result.map(\.id) == ["needs", "working", "idle"])
    }

    @Test("within a state, most recent activity wins")
    func recencyWithinState() {
        let result = ChatSessionDescriptor.openable([
            session("idle-old", .idle, ago: 100),
            session("idle-new", .idle, ago: 1),
        ])
        #expect(result.map(\.id) == ["idle-new", "idle-old"])
    }

    @Test("all ended falls back to showing ended, most recent first")
    func allEndedFallback() {
        let result = ChatSessionDescriptor.openable([
            session("ended-old", .ended, ago: 100),
            session("ended-new", .ended, ago: 1),
        ])
        #expect(result.map(\.id) == ["ended-new", "ended-old"])
    }
}
