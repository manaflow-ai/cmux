import Foundation
import Testing

@testable import CmuxDotTransport

@Suite("dot/1 wire codec")
struct DotWireTests {
    @Test func dataFrameRoundtrip() {
        let frame = DotWire.DataFrame(
            legID: 0x0102_0304, seq: 0x0A0B_0C0D_0E0F_1011,
            payload: Data("hello".utf8))
        let encoded = DotWire.encodeData(frame)
        #expect(encoded.count == DotWire.dataHeaderBytes + 5)
        #expect(DotWire.decodeData(encoded) == frame)
    }

    @Test func dataFrameRejectsMalformed() {
        #expect(DotWire.decodeData(Data([1, 1, 0])) == nil)
        // Wrong version / kind.
        var bad = DotWire.encodeData(.init(legID: 1, seq: 1, payload: Data()))
        bad[0] = 9
        #expect(DotWire.decodeData(bad) == nil)
        // seq 0 is invalid (streams start at 1).
        var zeroSeq = DotWire.encodeData(.init(legID: 1, seq: 1, payload: Data()))
        zeroSeq.replaceSubrange(6 ..< 14, with: Data(repeating: 0, count: 8))
        #expect(DotWire.decodeData(zeroSeq) == nil)
    }

    @Test func controlRoundtripThroughRelayShapes() throws {
        let hello = try DotControlFrame.hello(
            device: "phone-1", resume: "key", ack: 7, acks: nil
        ).encoded()
        let object = try JSONSerialization.jsonObject(
            with: Data(hello.utf8)) as? [String: Any]
        #expect(object?["t"] as? String == "hello")
        #expect(object?["proto"] as? String == "dot/1")
        #expect(object?["resume"] as? String == "key")
        #expect((object?["ack"] as? NSNumber)?.intValue == 7)

        let ack = try #require(
            try DotControlFrame.decode(#"{"t":"ackup","seq":42,"leg":3}"#))
        #expect(ack == .ackUp(seq: 42, leg: 3))

        let helloAck = try #require(try DotControlFrame.decode(
            #"{"t":"hello.ack","legId":2,"resumeKey":"r","epoch":"e","peerOnline":true,"replayed":5}"#
        ))
        #expect(helloAck == .helloAck(
            legID: 2, resumeKey: "r", epoch: "e", peerOnline: true, replayed: 5))

        // Unknown types are tolerated (forward compatibility), not errors.
        #expect(try DotControlFrame.decode(#"{"t":"future.thing"}"#) == nil)
    }
}

@Suite("leg ledger reliability bookkeeping")
struct DotLegLedgerTests {
    @Test func uploadSequencingAndAckupPruning() {
        var ledger = DotLegLedger(role: .phone)
        let first = ledger.recordUpload(payload: Data("a".utf8), destination: 0)
        let second = ledger.recordUpload(payload: Data("b".utf8), destination: 0)
        #expect(first?.seq == 1)
        #expect(second?.seq == 2)
        #expect(ledger.totalBufferedFrames == 2)

        ledger.handleAckUp(seq: 1, leg: nil)
        #expect(ledger.totalBufferedFrames == 1)
        #expect(ledger.framesForResend().map(\.seq) == [2])

        ledger.handleAckUp(seq: 2, leg: nil)
        #expect(ledger.totalBufferedFrames == 0)
        #expect(ledger.totalBufferedBytes == 0)
    }

    @Test func hostKeysUploadsPerPhoneLeg() {
        var ledger = DotLegLedger(role: .host)
        _ = ledger.recordUpload(payload: Data("x".utf8), destination: 7)
        _ = ledger.recordUpload(payload: Data("y".utf8), destination: 9)
        _ = ledger.recordUpload(payload: Data("z".utf8), destination: 7)
        // Per-destination seqs are independent streams.
        #expect(ledger.framesForResend().map { [$0.destination, UInt32($0.seq)] }
            == [[7, 1], [7, 2], [9, 1]])
        // ackup for leg 7 must not prune leg 9.
        ledger.handleAckUp(seq: 2, leg: 7)
        #expect(ledger.framesForResend().map(\.destination) == [9])
    }

    @Test func downloadDedupAndResumeAck() {
        var ledger = DotLegLedger(role: .phone)
        let acceptFirst = ledger.acceptDownload(source: 1, seq: 1)
        let acceptSecond = ledger.acceptDownload(source: 1, seq: 2)
        #expect(acceptFirst && acceptSecond)
        // Replay after resume overlap is dropped.
        let replaySecond = ledger.acceptDownload(source: 1, seq: 2)
        let replayFirst = ledger.acceptDownload(source: 1, seq: 1)
        #expect(!replaySecond && !replayFirst)
        // Forward jumps are accepted (receivers never regress).
        let forwardJump = ledger.acceptDownload(source: 1, seq: 9)
        #expect(forwardJump)
        #expect(ledger.resumeAck == 9)
    }

    @Test func ackCoalescing() {
        var ledger = DotLegLedger(role: .phone)
        var now: TimeInterval = 100
        let accepted = ledger.acceptDownload(source: 1, seq: 1)
        #expect(accepted)
        // A fresh stream acks its first frame promptly.
        let first = ledger.ackDecision(source: 1, now: now)
        #expect(first == .ack(seq: 1, leg: nil))
        // Within the interval and below the frame threshold: coalesce.
        _ = ledger.acceptDownload(source: 1, seq: 2)
        let early = ledger.ackDecision(source: 1, now: now + 0.05)
        #expect(early == .none)
        // The interval threshold flushes.
        now += 0.11
        let intervalFlush = ledger.ackDecision(source: 1, now: now)
        #expect(intervalFlush == .ack(seq: 2, leg: nil))
        // Nothing pending afterward.
        let drained = ledger.ackDecision(source: 1, now: now)
        #expect(drained == .none)
        // The frame-count threshold flushes without waiting for the interval.
        for seq in 3 ... 18 {
            let acceptedMore = ledger.acceptDownload(source: 1, seq: UInt64(seq))
            #expect(acceptedMore)
        }
        let countFlush = ledger.ackDecision(source: 1, now: now)
        #expect(countFlush == .ack(seq: 18, leg: nil))
    }

    @Test func overflowSignalsReset() {
        var ledger = DotLegLedger(role: .phone)
        let oversize = Data(repeating: 0, count: 1024 * 1024)
        for _ in 0 ..< 4 {
            _ = ledger.recordUpload(payload: oversize, destination: 0)
        }
        // The fifth megabyte crosses maxBufferedBytes: nil = caller resets.
        #expect(ledger.recordUpload(payload: oversize, destination: 0) == nil)
        ledger.resetForFreshSession()
        #expect(ledger.totalBufferedFrames == 0)
        let fresh = ledger.recordUpload(payload: Data("a".utf8), destination: 0)
        #expect(fresh?.seq == 1)
    }
}
