import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("RemotePTYBridgeInputFlow")
struct RemotePTYBridgeInputFlowTests {
    @Test("an ack for a seq that was never sent is a protocol violation")
    func ackForUnsentSeqReturnsNil() {
        let flow = RemotePTYBridgeInputFlow(
            maxPendingWrites: 4,
            maxPendingBytes: 1024,
            seqAckEnabled: true
        )
        // Nothing sent yet: any positive ack is out of range.
        #expect(flow.acknowledge(upTo: 1) == nil)

        guard let enqueued = flow.enqueue(Data("a".utf8)), let write = enqueued.writes.first else {
            Issue.record("expected an immediate write")
            return
        }
        #expect(write.seq == 1)
        // Acking the sent seq drains; acking past it is rejected.
        #expect(flow.acknowledge(upTo: 2) == nil)
        #expect(flow.acknowledge(upTo: 1) != nil)
    }

    @Test("legacy mode ignores acks without draining or failing")
    func legacyModeIgnoresAcks() {
        let flow = RemotePTYBridgeInputFlow(
            maxPendingWrites: 4,
            maxPendingBytes: 1024,
            seqAckEnabled: false
        )
        let result = flow.acknowledge(upTo: 99)
        #expect(result != nil)
        #expect(result?.writes.isEmpty == true)
        #expect(result?.shouldResumeReads == false)
    }
}
