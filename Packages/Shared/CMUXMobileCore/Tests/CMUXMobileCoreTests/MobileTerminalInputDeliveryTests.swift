import Foundation
import Testing
@testable import CMUXMobileCore

@Suite("Mobile terminal input delivery")
struct MobileTerminalInputDeliveryTests {
    private let surfaceA = UUID()
    private let surfaceB = UUID()
    private let stream = UUID()
    private let now = Date(timeIntervalSince1970: 1_000)

    // MARK: Frame

    @Test func deliveryFrameRoundTripsWithAndWithoutALatencyMarker() throws {
        let delivery = MobileTerminalInputDelivery(surfaceID: surfaceA, streamID: stream, sequence: 7)
        for marker in [nil, UInt64(42)] as [UInt64?] {
            var buffer = try MobileTerminalInputFrame(text: "ls\r", sequence: marker, delivery: delivery).encoded()
            let frames = try MobileTerminalInputFrame.decode(from: &buffer)
            #expect(frames == [MobileTerminalInputFrame(text: "ls\r", sequence: marker, delivery: delivery)])
            #expect(buffer.isEmpty)
        }
    }

    @Test func legacyAndMarkedFramesStillDecode() throws {
        var buffer = try MobileTerminalInputFrame(text: "a").encoded()
        buffer.append(try MobileTerminalInputFrame(text: "b", sequence: 9).encoded())
        let frames = try MobileTerminalInputFrame.decode(from: &buffer)
        #expect(frames.map(\.text) == ["a", "b"])
        #expect(frames.map(\.sequence) == [nil, 9])
        #expect(frames.allSatisfy { $0.delivery == nil })
    }

    @Test func partialDeliveryFrameWaitsForTheRest() throws {
        let delivery = MobileTerminalInputDelivery(surfaceID: surfaceA, streamID: stream, sequence: 1)
        let frame = try MobileTerminalInputFrame(text: "x", delivery: delivery).encoded()
        var buffer = frame.prefix(20)
        #expect(try MobileTerminalInputFrame.decode(from: &buffer).isEmpty)
        buffer.append(frame.dropFirst(20))
        #expect(try MobileTerminalInputFrame.decode(from: &buffer).first?.delivery == delivery)
    }

    // MARK: Acknowledgement

    @Test func acknowledgementRoundTripsOnTheLaneAndOverRPC() {
        for status in [MobileTerminalInputAcknowledgement.Status.applied, .duplicate, .gap,
                       .surfaceMismatch, .terminalUnavailable, .busy, .rejected] {
            let ack = MobileTerminalInputAcknowledgement(status: status, streamID: stream, sequence: 5, expected: 3)
            #expect(MobileTerminalInputAcknowledgement(decoding: ack.encoded()) == ack)
            #expect(MobileTerminalInputAcknowledgement.fromRPC(payload: ack.rpcPayload) == ack)
        }
    }

    @Test func rpcIdentityRequiresAStreamAndAPositiveSequence() {
        #expect(MobileTerminalInputDelivery.fromRPC(parameters: [:], surfaceID: surfaceA) == nil)
        #expect(MobileTerminalInputDelivery.fromRPC(
            parameters: ["input_stream_id": stream.uuidString, "input_stream_seq": "0"], surfaceID: surfaceA
        ) == nil)
        let delivery = MobileTerminalInputDelivery(surfaceID: surfaceA, streamID: stream, sequence: 3)
        #expect(MobileTerminalInputDelivery.fromRPC(parameters: delivery.rpcParameters, surfaceID: surfaceA) == delivery)
    }

    // MARK: Ledger

    @Test func ledgerAppliesInOrderSkipsDuplicatesAndReportsGaps() {
        var ledger = MobileTerminalInputLedger()
        let first = MobileTerminalInputDelivery(surfaceID: surfaceA, streamID: stream, sequence: 1)
        #expect(ledger.admit(first, now: now) == .apply)
        ledger.recordApplied(first, now: now)
        #expect(ledger.admit(first, now: now) == .duplicate(appliedThrough: 1))
        let third = MobileTerminalInputDelivery(surfaceID: surfaceA, streamID: stream, sequence: 3)
        #expect(ledger.admit(third, now: now) == .gap(expected: 2))
        let second = MobileTerminalInputDelivery(surfaceID: surfaceA, streamID: stream, sequence: 2)
        #expect(ledger.admit(second, now: now) == .apply)
        ledger.recordApplied(second, now: now)
        #expect(ledger.admit(third, now: now) == .apply)
    }

    @Test func aNewStreamMustStartAtOneSoAFastPathCannotOvertakeASlowOne() {
        var ledger = MobileTerminalInputLedger()
        // Unit 3 rode the lane and arrived before units 1 and 2 on the RPC.
        let third = MobileTerminalInputDelivery(surfaceID: surfaceA, streamID: stream, sequence: 3)
        #expect(ledger.admit(third, now: now) == .gap(expected: 1))
        let first = MobileTerminalInputDelivery(surfaceID: surfaceA, streamID: stream, sequence: 1)
        #expect(ledger.admit(first, now: now) == .apply)
    }

    @Test func aStreamNeverWritesToASecondTerminal() {
        var ledger = MobileTerminalInputLedger()
        let first = MobileTerminalInputDelivery(surfaceID: surfaceA, streamID: stream, sequence: 1)
        ledger.recordApplied(first, now: now)
        let crossing = MobileTerminalInputDelivery(surfaceID: surfaceB, streamID: stream, sequence: 2)
        #expect(ledger.admit(crossing, now: now) == .surfaceMismatch)
        ledger.recordApplied(crossing, now: now)
        #expect(ledger.appliedThrough(streamID: stream) == 1)
    }

    @Test func aRefusedUnitIsNotMarkedApplied() {
        var ledger = MobileTerminalInputLedger()
        let first = MobileTerminalInputDelivery(surfaceID: surfaceA, streamID: stream, sequence: 1)
        // The terminal refused it (queue full): the caller skips recordApplied.
        #expect(ledger.admit(first, now: now) == .apply)
        #expect(ledger.admit(first, now: now) == .apply)
    }

    @Test func ledgerEvictsTheLeastRecentlyUsedStream() {
        var ledger = MobileTerminalInputLedger(capacity: 2)
        let streams = [UUID(), UUID(), UUID()]
        for (offset, streamID) in streams.enumerated() {
            ledger.recordApplied(
                MobileTerminalInputDelivery(surfaceID: surfaceA, streamID: streamID, sequence: 1),
                now: now.addingTimeInterval(Double(offset))
            )
        }
        #expect(ledger.streamCount == 2)
        #expect(ledger.appliedThrough(streamID: streams[0]) == nil)
        #expect(ledger.appliedThrough(streamID: streams[2]) == 1)
    }

    // MARK: Outbox

    @Test func outboxKeepsUnitsUntilAcknowledgedAndResendsAfterRewind() {
        var outbox = MobileTerminalInputOutbox<String>(surfaceID: surfaceA, streamID: stream)
        let one = outbox.enqueue("a", byteCount: 1)
        let two = outbox.enqueue("b", byteCount: 1)
        #expect(one?.sequence == 1)
        #expect(two?.sequence == 2)
        #expect(outbox.nextUnsent()?.delivery.sequence == 1)
        outbox.markSent(1)
        outbox.markSent(2)
        #expect(outbox.nextUnsent() == nil)
        // The path failed ambiguously: both are resent with the same identity.
        outbox.rewindAll()
        #expect(outbox.nextUnsent()?.delivery == one)
        outbox.acknowledge(through: 1)
        #expect(outbox.entries.map(\.delivery.sequence) == [2])
        #expect(outbox.pendingBytes == 1)
    }

    @Test func gapRewindResendsOnlyFromTheExpectedSequence() {
        var outbox = MobileTerminalInputOutbox<String>(surfaceID: surfaceA, streamID: stream)
        for text in ["a", "b", "c"] { _ = outbox.enqueue(text, byteCount: 1) }
        for sequence in 1...3 { outbox.markSent(UInt64(sequence)) }
        outbox.acknowledge(through: 1)
        outbox.rewind(from: 2)
        #expect(outbox.nextUnsent()?.delivery.sequence == 2)
        #expect(outbox.entries.filter { !$0.isSent }.map(\.item) == ["b", "c"])
    }

    @Test func outboxRefusesInputPastItsByteCapInsteadOfDroppingOlderInput() {
        var outbox = MobileTerminalInputOutbox<String>(surfaceID: surfaceA, streamID: stream, maximumPendingBytes: 3)
        #expect(outbox.enqueue("ab", byteCount: 2) != nil)
        #expect(outbox.enqueue("cd", byteCount: 2) == nil)
        #expect(outbox.nextSequence == 2)
        #expect(outbox.entries.map(\.item) == ["ab"])
    }

    @Test func abandoningReturnsEveryPendingUnitInOrder() {
        var outbox = MobileTerminalInputOutbox<String>(surfaceID: surfaceA, streamID: stream)
        for text in ["a", "b"] { _ = outbox.enqueue(text, byteCount: 1) }
        #expect(outbox.abandonAll().map(\.item) == ["a", "b"])
        #expect(outbox.isEmpty)
        #expect(outbox.pendingBytes == 0)
    }

    // MARK: Acknowledgements on the outbox

    private func sentOutbox(_ items: [String]) -> MobileTerminalInputOutbox<String> {
        var outbox = MobileTerminalInputOutbox<String>(surfaceID: surfaceA, streamID: stream)
        for item in items { _ = outbox.enqueue(item, byteCount: 1) }
        for sequence in 1...UInt64(items.count) { outbox.markSent(sequence) }
        return outbox
    }

    private func ack(
        _ status: MobileTerminalInputAcknowledgement.Status,
        _ sequence: UInt64,
        expected: UInt64 = 0,
        stream streamID: UUID? = nil
    ) -> MobileTerminalInputAcknowledgement {
        MobileTerminalInputAcknowledgement(
            status: status,
            streamID: streamID ?? stream,
            sequence: sequence,
            expected: expected
        )
    }

    @Test func appliedAndDuplicateAcknowledgementsConfirmEverythingThroughTheirSequence() {
        var outbox = sentOutbox(["a", "b", "c"])
        let applied = outbox.apply(ack(.applied, 2))
        #expect(applied.outcome == .progressed)
        #expect(applied.delivered.map(\.item) == ["a", "b"])
        #expect(outbox.entries.map(\.item) == ["c"])
        #expect(outbox.apply(ack(.duplicate, 3)).outcome == .progressed)
        #expect(outbox.isEmpty)
        #expect(outbox.apply(ack(.applied, 3)).outcome == .ignored)
    }

    @Test func anAcknowledgementForAnotherStreamChangesNothing() {
        var outbox = sentOutbox(["a"])
        #expect(outbox.apply(ack(.applied, 1, stream: UUID())).outcome == .ignored)
        #expect(outbox.entries.count == 1)
    }

    @Test func aGapConfirmsTheAppliedPrefixAndResendsFromTheExpectedUnit() {
        var outbox = sentOutbox(["a", "b", "c"])
        #expect(outbox.apply(ack(.gap, 3, expected: 2)).outcome == .resend)
        #expect(outbox.entries.map(\.item) == ["b", "c"])
        #expect(outbox.nextUnsent()?.delivery.sequence == 2)
        #expect(outbox.streamID == stream)
    }

    @Test func aHostThatForgotTheStreamGetsThePendingUnitsOnANewStream() {
        var outbox = sentOutbox(["a", "b", "c"])
        _ = outbox.apply(ack(.applied, 1))
        // The Mac restarted: it expects 1 again, which this outbox saw applied.
        #expect(outbox.apply(ack(.gap, 2, expected: 1)).outcome == .resend)
        #expect(outbox.streamID != stream)
        #expect(outbox.entries.map(\.item) == ["b", "c"])
        #expect(outbox.entries.map(\.delivery.sequence) == [1, 2])
        #expect(outbox.entries.allSatisfy { !$0.isSent && $0.delivery.streamID == outbox.streamID })
        #expect(outbox.enqueue("d", byteCount: 1)?.sequence == 3)
    }

    @Test func aBusyTerminalKeepsTheUnitForALaterRetry() {
        var outbox = sentOutbox(["a", "b"])
        #expect(outbox.apply(ack(.busy, 2)).outcome == .retryLater)
        #expect(outbox.entries.map(\.item) == ["b"])
        #expect(outbox.nextUnsent()?.item == "b")
    }

    @Test func aUnitRefusedForTheWrongTerminalIsResentNotDropped() {
        var outbox = sentOutbox(["a", "b"])
        #expect(outbox.apply(ack(.surfaceMismatch, 1)).outcome == .resend)
        #expect(outbox.entries.map(\.item) == ["a", "b"])
        #expect(outbox.nextUnsent()?.delivery.sequence == 1)
    }

    @Test func aClosedTerminalReturnsEveryPendingUnitAsUndeliverable() {
        var outbox = sentOutbox(["a", "b"])
        let result = outbox.apply(ack(.terminalUnavailable, 1))
        #expect(result.outcome == .undeliverable)
        #expect(result.undeliverable.map(\.item) == ["a", "b"])
        #expect(outbox.isEmpty)
    }

    @Test func aRejectedUnitIsConsumedAndLaterUnitsKeepTheirStream() {
        var outbox = sentOutbox(["a", "image", "c"])
        let result = outbox.apply(ack(.rejected, 2))
        #expect(result.outcome == .progressed)
        #expect(result.delivered.map(\.item) == ["a"])
        #expect(result.undeliverable.map(\.item) == ["image"])
        #expect(outbox.entries.map(\.item) == ["c"])
        #expect(outbox.streamID == stream)
    }

    @Test func mergingOnlyTouchesAnUnsentTailUnitAndCountsItsBytes() {
        var outbox = MobileTerminalInputOutbox<Int>(surfaceID: surfaceA, streamID: stream, maximumPendingBytes: 4)
        _ = outbox.enqueue(3, byteCount: 1)
        #expect(outbox.mergeIntoLastUnsent(addingBytes: 2) { $0 += 2; return true })
        #expect(outbox.entries.map(\.item) == [5])
        #expect(outbox.pendingBytes == 3)
        #expect(!outbox.mergeIntoLastUnsent(addingBytes: 2) { $0 += 2; return true })
        #expect(outbox.entries.map(\.item) == [5])
        outbox.markSent(1)
        #expect(!outbox.mergeIntoLastUnsent(addingBytes: 1) { $0 += 1; return true })
        #expect(outbox.hasUnacknowledgedSend(before: 2))
        #expect(!outbox.hasUnacknowledgedSend(before: 1))
    }
}
