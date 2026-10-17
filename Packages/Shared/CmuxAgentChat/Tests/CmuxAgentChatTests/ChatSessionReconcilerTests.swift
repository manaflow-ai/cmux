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
        #expect(reducer.upsert(descriptor("s", version: 3, state: .working(since: .now))))
        #expect(!reducer.upsert(descriptor("s", version: 2, state: .ended)))
        #expect(reducer.descriptor(for: "s")?.version == 3)
    }

    @Test("List replacement keeps a concurrent newer push and removes gone sessions") {
        var reducer = ChatSessionReconciler()
        reducer.replace(with: [descriptor("gone", version: 1), descriptor("live", version: 4)])
        #expect(reducer.upsert(descriptor("live", version: 5, state: .working(since: .now))))
        reducer.replace(with: [descriptor("live", version: 1)])
        #expect(reducer.descriptor(for: "gone") == nil)
        #expect(reducer.descriptor(for: "live")?.version == 5)
    }

    @Test("Removal and state pushes are idempotent")
    func eventFolding() {
        var reducer = ChatSessionReconciler()
        reducer.replace(with: [descriptor("s", version: 1)])
        #expect(reducer.apply(sessionID: "s", event: .stateChanged(.needsInput(since: .now))))
        #expect(reducer.descriptor(for: "s")?.state.needsAttention == true)
        #expect(!reducer.apply(sessionID: "s", event: .stateChanged(.needsInput(since: .now))))
        #expect(reducer.apply(sessionID: "s", event: .sessionRemoved(version: 2)))
        #expect(!reducer.apply(sessionID: "s", event: .sessionRemoved(version: 3)))
    }
}
