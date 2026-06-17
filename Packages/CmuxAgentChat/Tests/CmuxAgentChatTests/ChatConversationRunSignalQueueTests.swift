import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("ChatConversationRunSignalQueue")
struct ChatConversationRunSignalQueueTests {
    @Test("event overflow is explicit and recovers")
    func eventOverflowIsExplicitAndRecovers() async {
        let queue = ChatConversationRunSignalQueue(limit: 2)

        await queue.enqueue(.event(.appended([Self.message(id: "m1", seq: 1)])))
        await queue.enqueue(.event(.stateChanged(.working(since: Date(timeIntervalSince1970: 1)))))
        await queue.enqueue(.event(.updated([Self.message(id: "m1", seq: 1, text: "edited")])))

        guard case .event(.stateChanged(.working(since: _))) = await queue.next() else {
            Issue.record("expected non-replayable state event to survive overflow")
            return
        }
        guard case .overflowed = await queue.next() else {
            Issue.record("expected overflow signal")
            return
        }

        await queue.enqueue(.event(.stateChanged(.idle)))
        guard case .event(.stateChanged(.idle)) = await queue.next() else {
            Issue.record("expected new event after overflow")
            return
        }

        await queue.close()
        #expect(await queue.next() == nil)
    }

    @Test("overflow preserves descriptor updates and suppresses replayable deltas")
    func overflowPreservesDescriptorUpdatesAndSuppressesReplayableDeltas() async {
        let queue = ChatConversationRunSignalQueue(limit: 3)
        let descriptor = ChatSessionDescriptor(
            id: "session-1",
            agentKind: .claude,
            title: "Real transcript",
            transcriptAvailability: .available
        )

        await queue.enqueue(.event(.appended([Self.message(id: "m1", seq: 1)])))
        await queue.enqueue(.event(.descriptorChanged(descriptor)))
        await queue.enqueue(.event(.terminalBlocks([])))
        await queue.enqueue(.event(.appended([Self.message(id: "m2", seq: 2)])))
        await queue.enqueue(.event(.updated([Self.message(id: "m3", seq: 3)])))

        guard case .event(.descriptorChanged(descriptor)) = await queue.next() else {
            Issue.record("expected descriptor update to survive overflow")
            return
        }
        guard case .event(.terminalBlocks(let blocks)) = await queue.next(), blocks.isEmpty else {
            Issue.record("expected terminal blocks to survive overflow")
            return
        }
        guard case .overflowed = await queue.next() else {
            Issue.record("expected overflow signal after preserved events")
            return
        }
        await queue.close()
        #expect(await queue.next() == nil)
    }

    @Test("non-replayable overflow coalesces to bounded latest snapshots")
    func nonReplayableOverflowCoalescesToBoundedLatestSnapshots() async {
        let queue = ChatConversationRunSignalQueue(limit: 4)
        let oldDescriptor = ChatSessionDescriptor(id: "session-1", agentKind: .claude, title: "Old")
        let newDescriptor = ChatSessionDescriptor(id: "session-1", agentKind: .claude, title: "New")
        let terminalBlock = TerminalCommandBlock(id: 1, command: "make", output: "building")

        await queue.enqueue(.event(.stateChanged(.working(since: Date(timeIntervalSince1970: 1)))))
        await queue.enqueue(.event(.descriptorChanged(oldDescriptor)))
        await queue.enqueue(.event(.terminalBlocks([terminalBlock])))
        await queue.enqueue(.event(.stateChanged(.idle)))
        await queue.enqueue(.event(.descriptorChanged(newDescriptor)))

        guard case .event(.descriptorChanged(newDescriptor)) = await queue.next() else {
            Issue.record("expected latest descriptor after coalescing")
            return
        }
        guard case .event(.stateChanged(.idle)) = await queue.next() else {
            Issue.record("expected latest state after coalescing")
            return
        }
        guard case .event(.terminalBlocks([terminalBlock])) = await queue.next() else {
            Issue.record("expected latest terminal blocks after coalescing")
            return
        }
        guard case .overflowed = await queue.next() else {
            Issue.record("expected overflow signal after coalescing")
            return
        }
        await queue.close()
        #expect(await queue.next() == nil)
    }

    private static func message(
        id: String,
        seq: Int,
        text: String = "hello"
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .prose(ChatProse(text: text))
        )
    }
}
