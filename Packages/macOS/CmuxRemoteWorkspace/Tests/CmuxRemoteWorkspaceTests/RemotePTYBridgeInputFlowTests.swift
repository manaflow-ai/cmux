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

    @Test("oversized input splits into bounded, ordered, seq-contiguous writes")
    func oversizedInputSplitsIntoBoundedWrites() {
        let flow = RemotePTYBridgeInputFlow(
            maxPendingWrites: 256,
            maxPendingBytes: 1024,
            seqAckEnabled: true,
            maxWriteBytes: 16
        )
        let input = Data((0..<100).map { UInt8($0) })
        guard let drain = flow.enqueue(input) else {
            Issue.record("enqueue should not overflow")
            return
        }
        #expect(drain.writes.allSatisfy { $0.data.count <= 16 })
        #expect(drain.writes.map(\.data).reduce(Data(), +) == input)
        #expect(drain.writes.compactMap(\.seq) == (1...UInt64(drain.writes.count)).map { $0 })
    }

    @Test("pieces past the window buffer in order and drain on ack")
    func windowBoundaryBuffersInOrder() {
        let flow = RemotePTYBridgeInputFlow(
            maxPendingWrites: 2,
            maxPendingBytes: 1024,
            seqAckEnabled: true,
            maxWriteBytes: 4
        )
        let input = Data("abcdefghij".utf8)
        guard let drain = flow.enqueue(input) else {
            Issue.record("enqueue should not overflow")
            return
        }
        // Window fits two 4-byte writes; the tail buffers and pauses reads.
        #expect(drain.writes.map(\.data) == [Data("abcd".utf8), Data("efgh".utf8)])
        #expect(flow.isPaused)
        guard let acked = flow.acknowledge(upTo: 2) else {
            Issue.record("ack of sent seqs should drain")
            return
        }
        #expect(acked.writes.map(\.data) == [Data("ij".utf8)])
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
