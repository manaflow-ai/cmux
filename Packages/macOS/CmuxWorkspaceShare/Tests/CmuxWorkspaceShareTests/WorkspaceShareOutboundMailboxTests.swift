import CmuxWorkspaceShare
import Testing

@Suite
struct WorkspaceShareOutboundMailboxTests {
    @Test
    func `Admission is byte and count bounded without eviction`() throws {
        let mailbox = WorkspaceShareOutboundMailbox<String>(
            maximumMessages: 4,
            maximumBytes: 100,
            reservedControlMessages: 1,
            reservedControlBytes: 20,
            reservedAcknowledgementMessages: 1,
            reservedAcknowledgementBytes: 10
        )

        #expect(mailbox.admit("bulk-1", byteCount: 35, priority: .bulk))
        #expect(mailbox.admit("bulk-2", byteCount: 35, priority: .bulk))
        #expect(!mailbox.admit("bulk-3", byteCount: 1, priority: .bulk))
        #expect(mailbox.pendingMessages == 2)
        #expect(mailbox.pendingBytes == 70)

        #expect(mailbox.admit("control", byteCount: 20, priority: .control))
        #expect(!mailbox.admit("control-2", byteCount: 1, priority: .control))
        #expect(mailbox.admit("ack", byteCount: 10, priority: .acknowledgement))
        #expect(mailbox.pendingMessages == 4)
        #expect(mailbox.pendingBytes == 100)

        let values = try drain(mailbox)
        #expect(values == ["ack", "control", "bulk-1", "bulk-2"])
        #expect(mailbox.pendingMessages == 0)
        #expect(mailbox.pendingBytes == 0)
    }

    @Test
    func `Handshake stays first and ACK bypasses queued bulk`() throws {
        let mailbox = WorkspaceShareOutboundMailbox<String>(
            maximumMessages: 8,
            maximumBytes: 1_000,
            reservedControlMessages: 1,
            reservedControlBytes: 100,
            reservedAcknowledgementMessages: 2,
            reservedAcknowledgementBytes: 100
        )
        #expect(mailbox.admit("grid-1", byteCount: 200, priority: .bulk))
        #expect(mailbox.admit("grid-2", byteCount: 200, priority: .bulk))
        #expect(mailbox.admit("focus", byteCount: 50, priority: .control))
        #expect(mailbox.admit("ack", byteCount: 10, priority: .acknowledgement))
        #expect(mailbox.admit("hello", byteCount: 50, priority: .handshake))

        #expect(
            try drain(mailbox)
                == ["hello", "ack", "focus", "grid-1", "grid-2"]
        )
    }

    @Test
    func `Resync ACK precedes replay hello and full grid`() throws {
        let mailbox = WorkspaceShareOutboundMailbox<String>(
            maximumMessages: 5,
            maximumBytes: 1_000,
            reservedControlMessages: 1,
            reservedControlBytes: 100,
            reservedAcknowledgementMessages: 2,
            reservedAcknowledgementBytes: 100
        )

        #expect(mailbox.admit("control-1", byteCount: 100, priority: .control))
        #expect(mailbox.admit("control-2", byteCount: 100, priority: .control))
        #expect(mailbox.admit("control-3", byteCount: 100, priority: .control))
        #expect(!mailbox.admit("control-full", byteCount: 1, priority: .control))
        _ = mailbox.beginAcknowledgementBarrier()
        #expect(mailbox.admitAcknowledgementAndReplayAndRelease(
            acknowledgement: "ack-resync",
            acknowledgementByteCount: 10,
            replay: "hello-replay",
            replayByteCount: 50
        ))

        #expect(
            try drain(mailbox)
                == [
                    "ack-resync",
                    "hello-replay",
                    "control-1",
                    "control-2",
                    "control-3",
                ]
        )
    }

    @Test
    func `Resync acknowledgement and replay reject atomically`() {
        let mailbox = WorkspaceShareOutboundMailbox<String>(
            maximumMessages: 1,
            maximumBytes: 100,
            reservedControlMessages: 0,
            reservedControlBytes: 0,
            reservedAcknowledgementMessages: 1,
            reservedAcknowledgementBytes: 100
        )

        _ = mailbox.beginAcknowledgementBarrier()
        #expect(!mailbox.admitAcknowledgementAndReplayAndRelease(
            acknowledgement: "ack-resync",
            acknowledgementByteCount: 10,
            replay: "hello-replay",
            replayByteCount: 50
        ))
        #expect(mailbox.pendingMessages == 0)
        #expect(mailbox.hasAcknowledgementBarrier)
    }

    @Test
    func `Accepted payload defers ordinary FIFO until ACK is admitted`() throws {
        let mailbox = WorkspaceShareOutboundMailbox<String>(
            maximumMessages: 8,
            maximumBytes: 1_000,
            reservedControlMessages: 1,
            reservedControlBytes: 100,
            reservedAcknowledgementMessages: 2,
            reservedAcknowledgementBytes: 100
        )
        var gate = WorkspaceShareAcknowledgementGate()
        gate.connectionOpened()
        gate.recordPayload(accepted: true, sequence: 4)
        #expect(mailbox.beginAcknowledgementBarrier().isEmpty)

        #expect(mailbox.admit("chat", byteCount: 20, priority: .control))
        #expect(mailbox.admit("input", byteCount: 20, priority: .control))
        #expect(mailbox.admit("grid", byteCount: 200, priority: .bulk))
        #expect(mailbox.hasPending)
        #expect(!mailbox.hasClaimablePending)
        #expect(mailbox.claimNext() == nil)

        let nonce = ShareAckNonce(rawValue: "credit")!
        let gatedNonce = gate.acknowledgement(for: nonce, sequence: 5)
        let acceptedNonce = try #require(gatedNonce)
        #expect(
            mailbox.admitAcknowledgementAndRelease(
                acceptedNonce.rawValue,
                byteCount: acceptedNonce.rawValue.utf8.count
            )
        )
        #expect(
            try drain(mailbox)
                == ["credit", "chat", "input", "grid"]
        )
    }

    @Test
    func `Displaced invalid orphan and close discard deferred batches`() {
        let mailbox = WorkspaceShareOutboundMailbox<String>(
            maximumMessages: 8,
            maximumBytes: 1_000,
            reservedControlMessages: 1,
            reservedControlBytes: 100,
            reservedAcknowledgementMessages: 2,
            reservedAcknowledgementBytes: 100
        )

        _ = mailbox.beginAcknowledgementBarrier()
        #expect(mailbox.admit("displaced", byteCount: 10, priority: .control))
        #expect(
            mailbox.beginAcknowledgementBarrier().map(\.payload)
                == ["displaced"]
        )
        #expect(mailbox.pendingMessages == 0)

        #expect(mailbox.admit("invalid", byteCount: 10, priority: .bulk))
        #expect(
            mailbox.discardAcknowledgementBarrier().map(\.payload)
                == ["invalid"]
        )
        #expect(mailbox.pendingMessages == 0)

        _ = mailbox.beginAcknowledgementBarrier()
        #expect(mailbox.admit("orphan", byteCount: 10, priority: .control))
        #expect(
            mailbox.discardAcknowledgementBarrier().map(\.payload)
                == ["orphan"]
        )

        _ = mailbox.beginAcknowledgementBarrier()
        #expect(mailbox.admit("close", byteCount: 10, priority: .bulk))
        #expect(mailbox.discardAll().map(\.payload) == ["close"])
        #expect(!mailbox.hasAcknowledgementBarrier)
        #expect(mailbox.pendingMessages == 0)
        #expect(mailbox.pendingBytes == 0)
    }

    @Test
    func `In-flight work stays budgeted and teardown releases it once`() throws {
        let mailbox = WorkspaceShareOutboundMailbox<String>(
            maximumMessages: 2,
            maximumBytes: 10,
            reservedControlMessages: 0,
            reservedControlBytes: 0,
            reservedAcknowledgementMessages: 0,
            reservedAcknowledgementBytes: 0
        )
        #expect(mailbox.admit("one", byteCount: 6, priority: .control))
        let claim = try #require(mailbox.claimNext())
        #expect(mailbox.pendingMessages == 1)
        #expect(mailbox.pendingBytes == 6)
        #expect(!mailbox.admit("two", byteCount: 5, priority: .control))

        let discarded = mailbox.discardAll()
        #expect(discarded.map(\.payload) == ["one"])
        #expect(mailbox.complete(claim) == nil)
        #expect(mailbox.pendingMessages == 0)
        #expect(mailbox.pendingBytes == 0)

        _ = mailbox.stop()
        #expect(!mailbox.admit("late", byteCount: 1, priority: .acknowledgement))
    }

    private func drain(
        _ mailbox: WorkspaceShareOutboundMailbox<String>
    ) throws -> [String] {
        var result: [String] = []
        while let claim = mailbox.claimNext() {
            result.append(claim.entry.payload)
            _ = try #require(mailbox.complete(claim))
        }
        return result
    }
}
