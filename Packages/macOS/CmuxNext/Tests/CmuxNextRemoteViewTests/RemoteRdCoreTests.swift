#if canImport(CCmuxRdFFI)
import CCmuxRdFFI
import Foundation
import Testing
@testable import CmuxNextRemoteView

/// The Rust viewer core through the client xcframework: `cmux.rd/1`
/// datagrams built from the cmux-rd-proto layout and golden vector in, access
/// units and feedback out.
struct RemoteRdCoreTests {
    /// The 16-byte header (cmux-rd-proto `DatagramHeader`, little-endian).
    static func header(
        flags: UInt8 = 0, kind: UInt8 = 1, stream: UInt16 = 0, frame: UInt32, index: UInt16, count: UInt16,
        fecCount: UInt16 = 0, transportSeq: UInt16
    ) -> [UInt8] {
        var out: [UInt8] = [0x10 | flags, kind]
        out += le(stream) + le(frame) + le(index) + le(count) + le(fecCount) + le(transportSeq)
        return out
    }

    static func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    /// A frame body (`u32 au_len, u64 t_capture_us, u32 ref_frame`, access
    /// unit) split into `shardLen`-byte data shards, the last zero-padded.
    static func datagrams(
        frame: UInt32, keyframe: Bool, accessUnit: [UInt8], tCapture: UInt64, shardLen: Int, firstSeq: UInt16
    ) -> [Data] {
        let ref: UInt32 = keyframe ? UInt32.max : frame - 1
        var body = le(UInt32(accessUnit.count)) + le(tCapture) + le(ref) + accessUnit
        let count = (body.count + shardLen - 1) / shardLen
        body += [UInt8](repeating: 0, count: count * shardLen - body.count)
        return (0..<count).map { i in
            let h = header(
                flags: keyframe ? 0x01 : 0, frame: frame, index: UInt16(i), count: UInt16(count),
                transportSeq: firstSeq &+ UInt16(i)
            )
            return Data(h + body[(i * shardLen)..<((i + 1) * shardLen)])
        }
    }

    static func annexB(_ nalType: UInt8, _ length: Int) -> [UInt8] {
        [0, 0, 0, 1, nalType] + (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31) }
    }

    @Test func headerMatchesTheProtoGoldenVector() {
        let bytes = Self.header(
            flags: 0x01, kind: 1, stream: 2, frame: 0x0102_0304, index: 1, count: 3, fecCount: 1, transportSeq: 0xbeef
        )
        #expect(bytes == [0x11, 0x01, 0x02, 0x00, 0x04, 0x03, 0x02, 0x01, 0x01, 0x00, 0x03, 0x00, 0x01, 0x00, 0xef, 0xbe])
    }

    @Test func importedLayoutsMatchTheRustSide() {
        #expect(MemoryLayout<CmuxRdFrame>.size == 40)
        #expect(MemoryLayout<CmuxRdMessage>.size == 24)
        #expect(MemoryLayout<CmuxRdStats>.size == 24)
        #expect(RemoteRdCore.abiVersion == UInt32(CMUX_RD_FFI_ABI_VERSION))
    }

    @Test func datagramsBecomeAccessUnitsInFrameOrder() throws {
        let core = try #require(RemoteRdCore(carrier: .datagram))
        let idr = Self.annexB(0x65, 300)
        let pFrame = Self.annexB(0x41, 90)
        let first = Self.datagrams(frame: 1, keyframe: true, accessUnit: idr, tCapture: 1_000, shardLen: 64, firstSeq: 0)
        let second = Self.datagrams(
            frame: 2, keyframe: false, accessUnit: pFrame, tCapture: 17_667, shardLen: 64, firstSeq: UInt16(first.count)
        )
        // The P-frame arrives first and waits for its reference; shards arrive out of order.
        for d in second.reversed() { try core.push(datagram: d, nowMicros: 10) }
        #expect(try core.popAccessUnit(codec: .h264) == nil)
        for d in first.reversed() { try core.push(datagram: d, nowMicros: 20) }
        let a = try #require(try core.popAccessUnit(codec: .h264))
        let b = try #require(try core.popAccessUnit(codec: .h264))
        #expect(try core.popAccessUnit(codec: .h264) == nil)
        #expect(a == RemoteAccessUnit(frame: 1, flags: .keyframe, tCaptureMicros: 1_000, data: Data(idr), codec: .h264))
        #expect(b == RemoteAccessUnit(frame: 2, flags: [], tCaptureMicros: 17_667, data: Data(pFrame), codec: .h264))
        #expect(try core.stats() == RemoteRdStats(ackedFrame: 2, needRecovery: false, framesReleased: 2, framesLost: 0))
    }

    @Test func feedbackAcknowledgesAndCarriesKeyframeRequests() throws {
        let core = try #require(RemoteRdCore(carrier: .datagram))
        for d in Self.datagrams(frame: 1, keyframe: true, accessUnit: Self.annexB(0x65, 50), tCapture: 5, shardLen: 32, firstSeq: 0) {
            try core.push(datagram: d, nowMicros: 100)
        }
        #expect(core.nextDeadlineMicros == 0)
        let feedback = try #require(try core.feedback(nowMicros: 100).first)
        // Header: version 1, kind 7 (feedback); payload: u32 acked, u32 decode, u8 need_recovery.
        #expect(Array(feedback.prefix(2)) == [0x10, 0x07])
        #expect(Array(feedback[16..<20]) == Self.le(UInt32(1)))
        #expect(feedback[24] == 0)
        #expect(try core.feedback(nowMicros: 100).isEmpty)
        // Keepalive within a second; nothing sooner while idle.
        #expect(core.nextDeadlineMicros == 1_000_100)

        try core.requestKeyframe()
        try core.noteDecode(micros: 900)
        let request = try #require(try core.feedback(nowMicros: 50_100).first)
        #expect(request[24] == 1)
        #expect(Array(request[20..<24]) == Self.le(UInt32(900)))
    }

    @Test func streamCarrierYieldsControlMessagesAndFrames() throws {
        let core = try #require(RemoteRdCore(carrier: .stream))
        let control = Data(#"{"t":"started","session":7}"#.utf8)
        var stream = try RemoteRdCore.streamFrame(control, control: true)
        let au = Self.annexB(0x65, 200)
        for d in Self.datagrams(frame: 1, keyframe: true, accessUnit: au, tCapture: 9, shardLen: 48, firstSeq: 0) {
            stream += try RemoteRdCore.streamFrame(d, control: false)
        }
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 3, stream.count)
            try core.push(streamBytes: stream.subdata(in: offset..<end), nowMicros: 1)
            offset = end
        }
        #expect(try core.popMessage() == .control(control))
        #expect(try core.popMessage() == nil)
        #expect(try core.popAccessUnit(codec: .hevc)?.data == Data(au))
        // Feedback on the stream carrier is a stream frame of type 2.
        let framed = try #require(try core.feedback(nowMicros: 2).first)
        #expect(framed.first == 2)
    }

    @Test func badInputIsRefused() throws {
        let core = try #require(RemoteRdCore(carrier: .datagram))
        #expect(throws: RemoteRdCoreError.invalid) { try core.push(datagram: Data([0x11, 0x01]), nowMicros: 0) }
        var wrongVersion = Self.header(frame: 1, index: 0, count: 1, transportSeq: 0)
        wrongVersion[0] = 0x21
        #expect(throws: RemoteRdCoreError.invalid) { try core.push(datagram: Data(wrongVersion), nowMicros: 0) }
        #expect(throws: RemoteRdCoreError.carrier) { try core.push(streamBytes: Data([1]), nowMicros: 0) }

        let stream = try #require(RemoteRdCore(carrier: .stream))
        #expect(throws: RemoteRdCoreError.failed) { try stream.push(streamBytes: Data([9, 0, 0, 0, 0]), nowMicros: 0) }
        // A broken stream stays broken.
        #expect(throws: RemoteRdCoreError.failed) { try stream.push(streamBytes: Data([1, 0, 0, 0, 0]), nowMicros: 0) }
    }

    @Test func aLostShardExpiresAtTheDeadlineAndAsksForRecovery() throws {
        let core = try #require(RemoteRdCore(carrier: .datagram, deadlineMicros: 1_000))
        let shards = Self.datagrams(frame: 1, keyframe: true, accessUnit: Self.annexB(0x65, 200), tCapture: 1, shardLen: 64, firstSeq: 0)
        _ = try core.feedback(nowMicros: 0)
        for d in shards.dropFirst() { try core.push(datagram: d, nowMicros: 10) }
        #expect(core.nextDeadlineMicros == 1_011)
        try core.tick(nowMicros: 1_011)
        #expect(try core.popAccessUnit(codec: .h264) == nil)
        let stats = try core.stats()
        #expect(stats.framesLost == 1)
        #expect(stats.needRecovery)
    }
}
#endif
