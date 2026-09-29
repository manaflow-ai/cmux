import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrxTransport

/// Collects every byte written to a lane.
private actor RecordingLaneWriter: IrxEventLaneWriting {
    private(set) var written: [Data] = []
    private(set) var finished = false

    func write(_ data: Data) async throws { written.append(data) }
    func setPriority(_: Int32) async throws {}
    func finish() async { finished = true }
    func reset(errorCode _: UInt64) async {}
}

/// Replays fixed chunks, then EOF.
private actor ScriptedLaneReader: IrxEventLaneReading {
    private var chunks: [Data]
    private(set) var stopCodes: [UInt64] = []

    init(_ chunks: [Data]) { self.chunks = chunks }

    func readRaw() async throws -> Data? {
        chunks.isEmpty ? nil : chunks.removeFirst()
    }

    func stop(errorCode: UInt64) { stopCodes.append(errorCode) }
}

private func renderGridLikeFrame(_ index: Int) throws -> Data {
    let payload = """
    {"kind":"event","topic":"terminal.render_grid","payload":{"format":"cmux.render-grid.v1",\
    "surface_id":"8C0A57A4-7F1B-4D0B-9C39-2F4E8B1A6D10","state_seq":\(1000 + index),\
    "render_epoch":"3E7C1D2A-55B0-4C8F-A1D2-9B7E6F5A4C3B","render_revision":\(index),\
    "columns":120,"rows":40,"full":false,"cleared_rows":[\(index % 40)],\
    "row_spans":[{"row":\(index % 40),"column":0,"style_id":3,"text":"line \(index) of build output"}]}}
    """
    return try MobileSyncFrameCodec.encodeFrame(Data(payload.utf8))
}

struct IrxLaneCompressionTests {
    @Test func deflatedLaneRoundTripsAcrossArbitraryChunkBoundaries() async throws {
        let frames = try (0..<200).map(renderGridLikeFrame)
        let sink = RecordingLaneWriter()
        let writer = try IrxEncodingLaneWriter(sink, encoding: .deflate)
        for frame in frames { try await writer.write(frame) }

        // Re-chunk the compressed stream at odd sizes, like QUIC reads do.
        let compressed = await sink.written.reduce(into: Data()) { $0.append($1) }
        var chunks: [Data] = []
        var offset = 0
        var size = 1
        while offset < compressed.count {
            let end = min(compressed.count, offset + size)
            chunks.append(compressed.subdata(in: offset..<end))
            offset = end
            size = size % 97 + 7
        }
        let reader = try IrxDecodingLaneReader(ScriptedLaneReader(chunks), encoding: .deflate)
        var decoded = Data()
        while let chunk = try await reader.readRaw() { decoded.append(chunk) }

        #expect(decoded == frames.reduce(into: Data()) { $0.append($1) })
        let raw = frames.reduce(0) { $0 + $1.count }
        // Consecutive frames share almost every byte; the stream must exploit it.
        #expect(compressed.count * 5 < raw)
    }

    @Test func everyWriteIsDecodableWithoutTheNextOne() async throws {
        let sink = RecordingLaneWriter()
        let writer = try IrxEncodingLaneWriter(sink, encoding: .deflate)
        let inflater = try IrxInflateStream()
        for index in 0..<20 {
            let frame = try renderGridLikeFrame(index)
            try await writer.write(frame)
            let written = await sink.written
            #expect(try inflater.decompress(written[index]) == frame)
        }
    }

    @Test func largeWriteCrossesScratchBuffers() async throws {
        var noise = Data(count: 300_000)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in noise.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            noise[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
        let deflater = try IrxDeflateStream()
        let inflater = try IrxInflateStream()
        #expect(try inflater.decompress(deflater.compress(noise)) == noise)
    }

    @Test func negotiationPicksFirstSupportedEncoding() {
        #expect(IrxLaneEncoding.negotiated(fromSubscribeParameter: "zstd, deflate") == .deflate)
        #expect(IrxLaneEncoding.negotiated(fromSubscribeParameter: "zstd") == nil)
        #expect(IrxLaneEncoding.negotiated(fromSubscribeParameter: nil) == nil)
        #expect(IrxLaneEncoding.negotiated(fromSubscribeParameter: 3) == nil)
    }

    @Test func descriptorOmitsEncodingForIdentityLanes() throws {
        let identity = try JSONEncoder().encode(IrxLaneDescriptor(lane: .events))
        #expect(!String(decoding: identity, as: UTF8.self).contains("encoding"))
        let encoded = try JSONEncoder().encode(IrxLaneDescriptor(lane: .events, encoding: .deflate))
        let decoded = try JSONDecoder().decode(IrxLaneDescriptor.self, from: encoded)
        #expect(decoded.encoding == "deflate")
    }

    @Test func hubDecodesEncodedLanesAndRefusesUnknownEncodings() async throws {
        let frames = try (0..<5).map(renderGridLikeFrame)
        let sink = RecordingLaneWriter()
        let writer = try IrxEncodingLaneWriter(sink, encoding: .deflate)
        for frame in frames { try await writer.write(frame) }
        let encodedLane = ScriptedLaneReader(await sink.written)
        var unknown = IrxLaneDescriptor(lane: .events, resource: "terminal:b")
        unknown.encoding = "brotli"
        let unknownLane = ScriptedLaneReader([frames[0]])
        let lanes: [(IrxLaneDescriptor, any IrxEventLaneReading)] = [
            (unknown, unknownLane),
            (IrxLaneDescriptor(lane: .events, resource: "terminal:a", encoding: .deflate), encodedLane),
        ]
        let queue = LaneQueue(lanes)
        let hub = IrxServerEventLaneHub(acceptLane: { await queue.next() })
        var received = Data()
        for try await chunk in await hub.subscribe() {
            received.append(chunk)
            if received.count >= frames.reduce(0, { $0 + $1.count }) { break }
        }
        #expect(received == frames.reduce(into: Data()) { $0.append($1) })
        #expect(await unknownLane.stopCodes == [IrxServerEventLaneHub.unsupportedLaneStopCode])
        await hub.stop()
    }
}

private actor LaneQueue {
    private var lanes: [(IrxLaneDescriptor, any IrxEventLaneReading)]
    private var parked: CheckedContinuation<Void, Never>?

    init(_ lanes: [(IrxLaneDescriptor, any IrxEventLaneReading)]) { self.lanes = lanes }

    /// Hands out each lane once, then parks like a connection with no new lanes.
    func next() async -> (IrxLaneDescriptor, any IrxEventLaneReading)? {
        if !lanes.isEmpty { return lanes.removeFirst() }
        await withCheckedContinuation { parked = $0 }
        return nil
    }
}
