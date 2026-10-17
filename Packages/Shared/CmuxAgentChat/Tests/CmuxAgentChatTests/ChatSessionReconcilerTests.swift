import Foundation
import Testing
@testable import CmuxAgentChat

@Suite("Chat session reconciliation")
struct ChatSessionReconcilerTests {
    private func descriptor(
        _ id: String,
        version: Int,
        state: ChatAgentState = .idle,
        kind: ChatAgentKind = .codex
    ) -> ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: id,
            agentKind: kind,
            title: id,
            state: state,
            version: version
        )
    }

    @Test("OpenCode is a first-class agent kind")
    func openCodeRoundTrips() throws {
        let kind = ChatAgentKind(source: "opencode")
        #expect(kind == .openCode)
        #expect(kind.sourceName == "opencode")
        #expect(kind.displayName == "OpenCode")
        let data = try JSONEncoder().encode(kind)
        #expect(try JSONDecoder().decode(ChatAgentKind.self, from: data) == .openCode)
    }

    @Test("Older descriptor pushes cannot overwrite newer state")
    func versionGating() {
        var reducer = ChatSessionReconciler()
        let firstApplied = reducer.upsert(descriptor("s", version: 3, state: .working(since: .now)))
        let staleApplied = reducer.upsert(descriptor("s", version: 2, state: .ended))
        #expect(firstApplied)
        #expect(!staleApplied)
        #expect(reducer.descriptor(for: "s")?.version == 3)
    }

    @Test("List replacement keeps a concurrent newer push and removes gone sessions")
    func listReplacement() {
        var reducer = ChatSessionReconciler()
        reducer.replace(with: [descriptor("gone", version: 1), descriptor("live", version: 4)])
        let liveUpdated = reducer.upsert(descriptor("live", version: 5, state: .working(since: .now)))
        #expect(liveUpdated)
        reducer.replace(with: [descriptor("live", version: 1)])
        #expect(reducer.descriptor(for: "gone") == nil)
        #expect(reducer.descriptor(for: "live")?.version == 5)
    }

    @Test("Ended sessions remain visible below live sessions")
    func endedSessionsRemainVisible() {
        var reducer = ChatSessionReconciler()
        reducer.replace(with: [
            descriptor("ended", version: 2, state: .ended),
            descriptor("live", version: 3, state: .idle),
        ])

        #expect(reducer.descriptors.map(\.id) == ["live", "ended"])
    }

    @Test("Snapshot replacement retains a push applied after the request began")
    func snapshotRace() {
        var reducer = ChatSessionReconciler()
        reducer.replace(with: [descriptor("live", version: 1)])
        let snapshotRevision = reducer.snapshotRevision
        _ = reducer.upsert(descriptor("new", version: 1, state: .working(since: .now)))
        reducer.replace(with: [descriptor("live", version: 1)], capturedAt: snapshotRevision)
        if case .working = reducer.descriptor(for: "new")?.state {
            #expect(true)
        } else {
            #expect(false)
        }
    }

    @Test("Removal and state pushes are idempotent")
    func eventFolding() {
        var reducer = ChatSessionReconciler()
        let eventDate = Date(timeIntervalSince1970: 123)
        reducer.replace(with: [descriptor("s", version: 1)])
        let stateApplied = reducer.apply(
            sessionID: "s",
            event: .stateChanged(.needsInput(since: eventDate), version: nil)
        )
        #expect(stateApplied)
        #expect(reducer.descriptor(for: "s")?.state.needsAttention == true)
        let duplicateStateApplied = reducer.apply(
            sessionID: "s",
            event: .stateChanged(.needsInput(since: eventDate), version: nil)
        )
        let removed = reducer.apply(sessionID: "s", event: .sessionRemoved(version: 2))
        let removedAgain = reducer.apply(sessionID: "s", event: .sessionRemoved(version: 3))
        #expect(!duplicateStateApplied)
        #expect(removed)
        #expect(!removedAgain)
    }

    @Test("A stale versioned state push cannot overwrite a newer descriptor")
    func versionedStatePushesAreMonotonic() {
        var reducer = ChatSessionReconciler()
        let date = Date(timeIntervalSince1970: 123)
        reducer.replace(with: [descriptor("s", version: 5)])

        let stale = reducer.apply(
            sessionID: "s",
            event: .stateChanged(.working(since: date), version: 4)
        )
        #expect(!stale)
        #expect(reducer.descriptor(for: "s")?.state == .idle)

        let current = reducer.apply(
            sessionID: "s",
            event: .stateChanged(.working(since: date), version: 6)
        )
        #expect(current)
        #expect(reducer.descriptor(for: "s")?.version == 6)
    }

    @Test("A stale descriptor cannot resurrect a removed session")
    func removalTombstone() {
        var reducer = ChatSessionReconciler()
        reducer.replace(with: [descriptor("s", version: 3)])
        let removed = reducer.apply(sessionID: "s", event: .sessionRemoved(version: 4))
        let equalVersionApplied = reducer.upsert(descriptor("s", version: 4))
        let olderVersionApplied = reducer.upsert(descriptor("s", version: 2))
        #expect(removed)
        #expect(!equalVersionApplied)
        #expect(!olderVersionApplied)
        #expect(reducer.descriptor(for: "s") == nil)
    }
}
