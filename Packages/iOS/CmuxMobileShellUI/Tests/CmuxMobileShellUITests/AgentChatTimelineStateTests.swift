#if os(iOS)
import CmuxAgentChat
import Testing
@testable import CmuxMobileShellUI

@Suite
struct AgentChatTimelineStateTests {
    @Test
    func appendAndUpdateReconcileByStableMessageID() {
        var state = AgentChatTimelineState(descriptor: descriptor(version: 1))
        let first = message(id: "m1", seq: 4, text: "running")
        state.apply(.appended([first, first]))

        #expect(state.messages == [first])

        let completed = message(id: "m1", seq: 4, text: "completed")
        state.apply(.updated([completed]))
        #expect(state.messages == [completed])
    }

    @Test
    func historyPaginationAndResetKeepTimelineAnchored() {
        var state = AgentChatTimelineState(descriptor: descriptor(version: 2))
        let newest = message(id: "new", seq: 10, text: "new")
        let older = message(id: "old", seq: 2, text: "old")
        state.mergeHistory(ChatHistoryPage(messages: [newest], hasMore: true), prepending: false)
        state.mergeHistory(ChatHistoryPage(messages: [older], hasMore: false), prepending: true)

        #expect(state.messages.map(\.id) == ["old", "new"])
        #expect(state.hasMoreHistory == false)

        state.apply(.reset)
        #expect(state.messages.isEmpty)
        #expect(state.streamingProse == nil)
        #expect(state.hasMoreHistory == false)
    }

    @Test
    func streamingProseIsClearedByAuthoritativeProseAndVersionsGateDescriptors() {
        var state = AgentChatTimelineState(descriptor: descriptor(version: 2))
        let preview = message(id: "preview", seq: 20, text: "draft")
        state.apply(.streamingProse(preview))
        #expect(state.streamingProse == preview)

        let stale = descriptor(version: 1, title: "stale")
        state.apply(.descriptorChanged(stale))
        #expect(state.descriptor.version == 2)

        state.apply(.appended([message(id: "final", seq: 20, text: "final")]))
        #expect(state.streamingProse == nil)

        let current = descriptor(version: 3, title: "current")
        state.apply(.descriptorChanged(current))
        #expect(state.descriptor == current)
    }

    private func descriptor(version: Int, title: String? = "Session") -> ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: "session",
            agentKind: .claude,
            title: title,
            workspaceID: "workspace",
            terminalID: "terminal",
            state: .idle,
            version: version
        )
    }

    private func message(id: String, seq: Int, text: String) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .prose(ChatProse(text: text))
        )
    }
}
#endif
