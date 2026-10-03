import Foundation
import Testing
import CmuxTerminalStream

private func ready(_ text: String, gen: UInt32 = 1, at offset: UInt64, version: UInt16 = 1) -> TerminalFrame {
    TerminalFrame(kind: .snapshotReady, generation: gen, offset: offset, snapshotVersion: version, payload: Data(text.utf8))
}

private func bytes(_ text: String, gen: UInt32 = 1, after offset: UInt64) -> TerminalFrame {
    TerminalFrame(kind: .bytes, generation: gen, offset: offset, payload: Data(text.utf8))
}

@Suite struct TerminalFrameTests {
    @Test func roundTripsEveryKindLittleEndian() throws {
        let frames = [
            TerminalFrame(kind: .bytes, generation: 7, offset: 0x0102_0304_0506_0708, payload: Data("hi".utf8)),
            TerminalFrame(kind: .snapshotReady, generation: 8, offset: 9, snapshotVersion: 1, payload: Data([1, 2])),
            TerminalFrame(kind: .snapshotHistory, generation: 8, offset: 9, snapshotVersion: 1, payload: Data()),
            TerminalFrame(kind: .digest, generation: 8, offset: 9, snapshotVersion: 1, payload: Data(repeating: 0xAB, count: 32)),
        ]
        for frame in frames { #expect(try TerminalFrame(decoding: frame.encoded) == frame) }
        // generation 7 LE, then offset LE: the low byte first.
        #expect([UInt8](frames[0].encoded.prefix(6)) == [0, 7, 0, 0, 0, 0x08])
    }

    @Test func decodesASliceAndSkipsUnknownKinds() throws {
        let frame = TerminalFrame(kind: .bytes, generation: 1, offset: 2, payload: Data("z".utf8))
        let padded = Data([0xFF, 0xFF]) + frame.encoded
        #expect(try TerminalFrame(decoding: padded.dropFirst(2)) == frame)
        #expect(try TerminalFrame.decodeSkippingUnknown(Data([9] + Array(repeating: 0, count: 12))) == nil)
    }

    @Test func rejectsShortAndUnknownFrames() {
        #expect(throws: TerminalFrame.DecodeError.truncated) { try TerminalFrame(decoding: Data([0, 1, 2])) }
        #expect(throws: TerminalFrame.DecodeError.unknownKind(9)) { try TerminalFrame(decoding: Data([9] + Array(repeating: 0, count: 12))) }
        #expect(throws: TerminalFrame.DecodeError.missingVersion) { try TerminalFrame(decoding: Data([1] + Array(repeating: 0, count: 12))) }
    }
}

private final class Counter: @unchecked Sendable {
    var n = 0
    func next() -> String { n += 1; return "r\(n)" }
}

private func req(_ reason: SnapshotRequest.Reason, _ id: String = "r1", gen: UInt32 = 1, at offset: UInt64) -> TerminalViewerAction {
    .requestSnapshot(SnapshotRequest(terminal: "t1", reason: reason,
                                     have: .init(generation: gen, offset: offset, snapshotVersion: 1), requestID: id))
}

@Suite struct TerminalViewerTests {
    @Test func bytesWaitForTheFirstSnapshotThenFollowIt() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        #expect(viewer.receive(bytes("early", after: 5)).isEmpty)
        #expect(viewer.receive(ready("SNAP", at: 5)) == [.restore(Data("SNAP".utf8), generation: 1)])
        #expect(viewer.receive(bytes("abc", after: 8)) == [.feed(Data("abc".utf8))])
        #expect(viewer.offset == 8)
        #expect(viewer.mode == .live)
    }

    @Test func duplicatesAreDroppedAndOverlapsFeedOnlyTheNewTail() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        _ = viewer.receive(ready("S", at: 10))
        #expect(viewer.receive(bytes("old", after: 10)).isEmpty)
        #expect(viewer.receive(bytes("xyz", after: 12)) == [.feed(Data("yz".utf8))])
    }

    @Test func aGapRequestsOneSnapshotAndDropsBytesUntilIt() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        _ = viewer.receive(ready("S", at: 10))
        #expect(viewer.receive(bytes("lost", after: 20)) == [req(.gap, at: 10)])
        #expect(viewer.receive(bytes("more", after: 24)).isEmpty)
        #expect(viewer.receive(ready("S2", at: 24)) == [.restore(Data("S2".utf8), generation: 1)])
        #expect(viewer.receive(bytes("ok", after: 26)) == [.feed(Data("ok".utf8))])
    }

    @Test func bytesOlderThanTheRestoredGenerationAreStale() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        _ = viewer.receive(ready("S", gen: 3, at: 10))
        #expect(viewer.receive(bytes("stale", gen: 2, after: 15)).isEmpty)
        #expect(viewer.offset == 10)
    }

    @Test func historyPrependsOnlyForTheCurrentGeneration() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        _ = viewer.receive(ready("S", gen: 2, at: 1))
        let page = TerminalFrame(kind: .snapshotHistory, generation: 2, offset: 1, snapshotVersion: 1, payload: Data("H".utf8))
        let old = TerminalFrame(kind: .snapshotHistory, generation: 1, offset: 1, snapshotVersion: 1, payload: Data("X".utf8))
        #expect(viewer.receive(page) == [.prependHistory(Data("H".utf8))])
        #expect(viewer.receive(old).isEmpty)
    }

    @Test func aDigestMismatchResyncsAndAMatchOrNoEncoderDoesNot() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        _ = viewer.receive(ready("S", at: 4))
        let digest = TerminalFrame(kind: .digest, generation: 1, offset: 4, snapshotVersion: 1, payload: Data(repeating: 1, count: 32))
        #expect(viewer.receive(digest).isEmpty)
        #expect(viewer.receive(digest, localDigest: { Data(repeating: 1, count: 32) }).isEmpty)
        #expect(viewer.receive(digest, localDigest: { Data(repeating: 2, count: 32) }) == [req(.digestMismatch, at: 4)])
        #expect(viewer.mode == .awaitingSnapshot)
    }

    @Test func anotherSnapshotVersionSwitchesToByteReplay() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        #expect(viewer.receive(ready("S", at: 1, version: 2)) == [.versionMismatch(host: 2)])
        let digest = TerminalFrame(kind: .digest, generation: 1, offset: 1, snapshotVersion: 2, payload: Data())
        #expect(viewer.receive(digest, localDigest: { Data([9]) }).isEmpty)
        #expect(viewer.receive(bytes("replay", after: 6)) == [.feed(Data("replay".utf8))])
        #expect(viewer.receive(bytes("ay!", after: 7)) == [.feed(Data("!".utf8))])
        #expect(viewer.mode == .replay)
    }

    @Test func newerGenerationBytesWithoutTheirSnapshotArePending() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        _ = viewer.receive(ready("S", gen: 1, at: 2))
        #expect(viewer.receive(bytes("x", gen: 2, after: 3)) == [req(.generationMismatch, at: 2)])
        #expect(viewer.receive(bytes("y", gen: 2, after: 4)).isEmpty)
    }

    @Test func emptyAndImpossibleBytesFrames() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        _ = viewer.receive(ready("S", at: 5))
        #expect(viewer.receive(bytes("", after: 5)).isEmpty)
        #expect(viewer.receive(bytes("toolong", after: 3)) == [req(.gap, at: 5)])
    }

    @Test func aLaterSnapshotAtALowerOffsetReplacesState() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        _ = viewer.receive(ready("S", at: 50))
        #expect(viewer.receive(ready("T", gen: 2, at: 0)) == [.restore(Data("T".utf8), generation: 2)])
        #expect(viewer.receive(bytes("ab", gen: 2, after: 2)) == [.feed(Data("ab".utf8))])
    }

    @Test func historyFromAnEarlierSnapshotOfTheSameGenerationIsDropped() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        _ = viewer.receive(ready("S", at: 10))
        _ = viewer.receive(ready("S2", at: 20))
        let stale = TerminalFrame(kind: .snapshotHistory, generation: 1, offset: 10, snapshotVersion: 1, payload: Data("H".utf8))
        let current = TerminalFrame(kind: .snapshotHistory, generation: 1, offset: 20, snapshotVersion: 1, payload: Data("I".utf8))
        #expect(viewer.receive(stale).isEmpty)
        #expect(viewer.receive(current) == [.prependHistory(Data("I".utf8))])
    }

    @Test func oneRequestInFlightAndAReadyClearsIt() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        _ = viewer.receive(ready("S", at: 10))
        #expect(viewer.receive(bytes("lost", after: 20)) == [req(.gap, at: 10)])
        #expect(viewer.attachRequest().isEmpty)
        _ = viewer.receive(ready("S2", at: 30))
        #expect(viewer.inFlight == nil)
        #expect(viewer.receive(bytes("x", gen: 2, after: 31)) == [req(.generationMismatch, "r2", at: 30)])
    }

    @Test func throttledRequestsRetryWithTheSameIDUnlessAReadyCame() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        _ = viewer.receive(ready("S", at: 10))
        _ = viewer.receive(bytes("lost", after: 20))
        #expect(viewer.throttled(retryAfterMilliseconds: 500, requestID: "r1") == [.retryAfter(milliseconds: 500)])
        #expect(viewer.retryDue() == [req(.gap, at: 10)])
        _ = viewer.receive(ready("S2", at: 30))
        #expect(viewer.retryDue().isEmpty)
        #expect(viewer.throttled(retryAfterMilliseconds: 500, requestID: "r1").isEmpty)
    }

    @Test func attachRequestHasNoHaveAndTheJSONMatchesTheSpec() throws {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        let actions = viewer.attachRequest()
        guard case .requestSnapshot(let request) = try #require(actions.first) else { Issue.record("no request"); return }
        #expect(request == SnapshotRequest(terminal: "t1", reason: .attach, have: nil, requestID: "r1"))
        let json = request.json
        #expect(json["type"] as? String == "snapshot_request")
        #expect(json["reason"] as? String == "attach")
        #expect(json["request_id"] as? String == "r1")
        #expect(json["have"] is NSNull)
        let held = SnapshotRequest(terminal: "t1", reason: .digestMismatch,
                                   have: .init(generation: 3, offset: 9, snapshotVersion: 1), requestID: "r2").json
        #expect(held["have"] as? [String: Any] != nil)
        let data = try JSONSerialization.data(withJSONObject: held, options: [.sortedKeys])
        #expect(String(decoding: data, as: UTF8.self).contains(#""have":{"generation":3,"offset":9,"snapshot_version":1}"#))
        #expect(String(decoding: data, as: UTF8.self).contains(#""reason":"digest_mismatch""#))
    }

    @Test func aResetConnectionForgetsTheRequestAndAttachGetsANewID() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        _ = viewer.receive(ready("S", at: 10))
        _ = viewer.receive(bytes("lost", after: 20))
        viewer.connectionReset()
        #expect(viewer.inFlight == nil)
        guard case .requestSnapshot(let again)? = viewer.attachRequest().first else { Issue.record("no request"); return }
        #expect(again.requestID == "r2" && again.reason == .attach)
        #expect(again.have == .init(generation: 1, offset: 10, snapshotVersion: 1))
    }

    @Test func aVersionMismatchClearsTheRequest() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        _ = viewer.attachRequest()
        _ = viewer.receive(ready("S", at: 1, version: 2))
        #expect(viewer.inFlight == nil)
    }

    @Test func lateOrStrayThrottlesAreIgnoredAndASecondTriggerSendsNothing() {
        var viewer = TerminalViewer(terminal: "t1", snapshotVersion: 1, makeRequestID: Counter().next)
        #expect(viewer.throttled(retryAfterMilliseconds: 500, requestID: "r1").isEmpty)
        _ = viewer.receive(ready("S", at: 4))
        _ = viewer.receive(bytes("lost", after: 20))
        let digest = TerminalFrame(kind: .digest, generation: 1, offset: 4, snapshotVersion: 1, payload: Data([1]))
        #expect(viewer.receive(digest, localDigest: { Data([2]) }).isEmpty)
        #expect(viewer.throttled(retryAfterMilliseconds: 500, requestID: "r0").isEmpty)
        #expect(viewer.throttled(retryAfterMilliseconds: 500, requestID: "r1") == [.retryAfter(milliseconds: 500)])
    }
}
