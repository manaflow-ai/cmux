import Foundation
import Testing

@testable import CmuxDorTransport

@Suite("dor/1 wire codec")
struct DorWireTests {
    @Test func remoteTextIsBoundedAndReasonsAreStable() {
        let hostile = "ok\u{0000}\u{001b}[31m" + String(repeating: "x", count: 800)
        let bounded = DorSafety.boundedText(hostile, fallback: "fallback")
        #expect(bounded.utf8.count <= DorSafety.maxAttributeBytes)
        #expect(!bounded.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f })
        #expect(DorSafety.stableReason("grant:secret", fallback: "denied") == "denied")
        #expect(DorSafety.relayReason("unknown session") == "unknown-session")
    }

    @Test func journalValuesRedactCredentialFields() {
        #expect(DorSafety.journalValue(key: "token", value: "bearer-secret") == "[redacted]")
        #expect(DorSafety.journalValue(key: "stderr", value: "private path") == "[redacted]")
        #expect(DorSafety.journalValue(key: "device", value: "device-1") == "device-1")
    }

    @Test func relayURLPolicyAllowsTLSAndLoopbackOnlyForCleartext() throws {
        #expect(DorLeg.isAllowedRelayBaseURL(try #require(URL(string: "https://presence.example"))))
        #expect(DorLeg.isAllowedRelayBaseURL(try #require(URL(string: "http://127.0.0.1:8787"))))
        #expect(DorLeg.isAllowedRelayBaseURL(try #require(URL(string: "ws://localhost:8787"))))
        #expect(!DorLeg.isAllowedRelayBaseURL(try #require(URL(string: "http://presence.example"))))
        #expect(!DorLeg.isAllowedRelayBaseURL(try #require(URL(string: "ws://198.51.100.2"))))
        #expect(!DorLeg.isAllowedRelayBaseURL(try #require(URL(string: "ftp://presence.example"))))
        #expect(!DorLeg.isAllowedRelayBaseURL(try #require(URL(string: "https://user:password@presence.example"))))
    }

    @Test func dataFrameRoundTrip() throws {
        let frame = DorWire.DataFrame(legID: 7, seq: 42, payload: Data("hello".utf8))
        let decoded = try #require(DorWire.decodeData(DorWire.encodeData(frame)))
        #expect(decoded == frame)
    }

    @Test func rejectsMalformedData() {
        #expect(DorWire.decodeData(Data([1, 1, 0])) == nil)
        // seq 0 is invalid
        let zeroSeq = DorWire.encodeData(.init(legID: 1, seq: 1, payload: Data()))
            .prefix(6) + Data(repeating: 0, count: 8)
        #expect(DorWire.decodeData(Data(zeroSeq)) == nil)
        // wrong version
        var wrongVersion = DorWire.encodeData(.init(legID: 1, seq: 1, payload: Data()))
        wrongVersion[0] = 9
        #expect(DorWire.decodeData(wrongVersion) == nil)
    }

    @Test func helloEncodesResumeAndAcks() throws {
        let text = try DorControlFrame.hello(
            device: "phone-1", resume: "key", ack: nil, acks: [3: 9]
        ).encoded()
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["t"] as? String == "hello")
        #expect(object["proto"] as? String == "dor/1")
        #expect(object["resume"] as? String == "key")
        #expect((object["acks"] as? [String: Int])?["3"] == 9)
    }

    @Test func decodesRelayFrames() throws {
        let ack = try DorControlFrame.decode(
            #"{"t":"hello.ack","legId":4,"resumeKey":"rk","epoch":"e","peerOnline":true,"replayed":2}"#)
        #expect(ack == .helloAck(legID: 4, resumeKey: "rk", epoch: "e", peerOnline: true, replayed: 2))
        let ackup = try DorControlFrame.decode(#"{"t":"ackup","seq":12,"leg":4}"#)
        #expect(ackup == .ackUp(seq: 12, leg: 4))
        // Unknown types are skipped, not fatal.
        #expect(try DorControlFrame.decode(#"{"t":"future-frame"}"#) == nil)
    }
}

@Suite("upload/download ledger")
struct DorLedgerTests {
    @Test func uploadSequencingAndAckupPruning() {
        var ledger = DorLedger(role: .phone)
        let first = ledger.recordUpload(payload: Data("a".utf8), destination: 0)
        let second = ledger.recordUpload(payload: Data("b".utf8), destination: 0)
        #expect(first?.seq == 1)
        #expect(second?.seq == 2)
        #expect(ledger.totalBufferedFrames == 2)
        ledger.handleAckUp(seq: 1, leg: nil)
        #expect(ledger.totalBufferedFrames == 1)
        #expect(ledger.framesForResend().map(\.seq) == [2])
    }

    @Test func hostResendPreservesPerDestinationOrder() {
        var ledger = DorLedger(role: .host)
        _ = ledger.recordUpload(payload: Data("a1".utf8), destination: 9)
        _ = ledger.recordUpload(payload: Data("b1".utf8), destination: 3)
        _ = ledger.recordUpload(payload: Data("a2".utf8), destination: 9)
        let resend = ledger.framesForResend()
        let toNine = resend.filter { $0.destination == 9 }.map(\.seq)
        #expect(toNine == [1, 2])
        // Per-destination seqs are independent streams.
        #expect(resend.filter { $0.destination == 3 }.map(\.seq) == [1])
    }

    @Test func downloadDedupAndResumeFloor() {
        var ledger = DorLedger(role: .phone)
        let outcomes = [
            ledger.acceptDownload(source: 1, seq: 1),
            ledger.acceptDownload(source: 1, seq: 2),
            ledger.acceptDownload(source: 1, seq: 2), // replay
            ledger.acceptDownload(source: 1, seq: 1), // replay
            ledger.acceptDownload(source: 1, seq: 5), // forward gap rejected
        ]
        #expect(outcomes == [true, true, false, false, false])
        #expect(ledger.resumeAck == 2)
    }

    @Test func hostResumeAcksAreKeyedByPhoneLeg() {
        var ledger = DorLedger(role: .host)
        let first = ledger.acceptDownload(source: 11, seq: 1)
        let second = ledger.acceptDownload(source: 12, seq: 1)
        #expect(first && second)
        #expect(ledger.resumeAcks == [11: 1, 12: 1])
    }

    @Test func coalescedAcksFlushByCountAndTime() {
        var ledger = DorLedger(role: .phone)
        for seq in 1...16 {
            _ = ledger.acceptDownload(source: 1, seq: UInt64(seq))
        }
        // 16 pending: count trigger fires immediately.
        let atCount = ledger.ackDecision(source: 1, now: 0.0)
        #expect(atCount == .ack(seq: 16, leg: nil))
        _ = ledger.acceptDownload(source: 1, seq: 17)
        // 1 pending, no time elapsed: hold.
        let held = ledger.ackDecision(source: 1, now: 0.05)
        #expect(held == .none)
        // Interval elapsed: flush.
        let flushed = ledger.ackDecision(source: 1, now: 0.2)
        #expect(flushed == .ack(seq: 17, leg: nil))
        _ = ledger.acceptDownload(source: 1, seq: 18)
        let idle = ledger.flushAcks(now: 0.21)
        #expect(idle == [.ack(seq: 18, leg: nil)])
    }

    @Test func overflowReturnsNilAndResetClears() {
        var ledger = DorLedger(role: .phone)
        for _ in 0..<DorLedger.maxBufferedFrames {
            let frame = ledger.recordUpload(payload: Data([0]), destination: 0)
            #expect(frame != nil)
        }
        let overflow = ledger.recordUpload(payload: Data([0]), destination: 0)
        #expect(overflow == nil)
        ledger.resetForFreshSession()
        #expect(ledger.totalBufferedFrames == 0)
        let fresh = ledger.recordUpload(payload: Data([0]), destination: 0)
        #expect(fresh?.seq == 1)
    }
}
