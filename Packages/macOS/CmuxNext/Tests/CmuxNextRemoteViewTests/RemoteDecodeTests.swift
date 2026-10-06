import CoreVideo
import Foundation
import Synchronization
import Testing
@testable import CmuxNextRemoteView

/// Round trip through VideoToolbox: the mock host paints a frame with the
/// counter marker, encodes it, and the pane's decoder reads the marker back
/// from the decoded NV12 pixels.
@Suite(.timeLimit(.minutes(1)))
struct RemoteDecodeTests {
    /// The next `count` access units; `trigger` runs after the stream exists
    /// (default: `count` damages).
    private func units(
        _ source: MockRemoteStreamSource, count: Int, trigger: ((MockRemoteStreamSource) -> Void)? = nil
    ) async -> [RemoteAccessUnit] {
        let stream = source.accessUnits()
        if let trigger { trigger(source) } else { for _ in 0..<count { source.damage() } }
        var collected: [RemoteAccessUnit] = []
        for await unit in stream {
            collected.append(unit)
            if collected.count == count { break }
        }
        return collected
    }

    @Test(arguments: RemoteVideoCodec.allCases)
    func encodedMarkerSurvivesDecode(codec: RemoteVideoCodec) async throws {
        let source = MockRemoteStreamSource(codec: codec, width: 1280, height: 720)
        try #require(source.canEncode, "no \(codec) encoder on this Mac")
        let encoded = await units(source, count: 3)
        #expect(encoded.map(\.frame) == [0, 1, 2])
        #expect(encoded[0].isKeyframe)
        #expect(!encoded[1].isKeyframe)
        let decoder = RemoteVideoDecoder()
        for (index, unit) in encoded.enumerated() {
            let image = try decoder.decode(unit)
            #expect(CVPixelBufferGetWidth(image) == 1280)
            #expect(CVPixelBufferGetHeight(image) == 720)
            #expect(CVPixelBufferGetIOSurface(image) != nil)
            #expect(CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            #expect(RemoteFrameMarker.read(image) == UInt16(index + 1))
        }
    }

    @Test func predictedFrameBeforeAnyKeyframeAsksForOne() async throws {
        let source = MockRemoteStreamSource(width: 1280, height: 720)
        try #require(source.canEncode)
        let encoded = await units(source, count: 2)
        let host = KeyframeCounter()
        let delivered = Mutex<[UInt32]>([])
        let pipeline = RemoteDecodePipeline(source: host) { frame in delivered.withLock { $0.append(frame.frame) } }
        #expect(await pipeline.decode(encoded[1]) == .skippedAwaitingKeyframe)
        #expect(host.requests == 1)
        #expect(await pipeline.decode(encoded[0]) == .decoded)
        #expect(await pipeline.decode(encoded[1]) == .decoded)
        #expect(delivered.withLock { $0 } == [0, 1])
    }

    @Test func frameGapStopsDisplayUntilTheNextKeyframe() async throws {
        let source = MockRemoteStreamSource(width: 1280, height: 720)
        try #require(source.canEncode)
        let first = await units(source, count: 3)
        let refreshed = await units(source, count: 1) { $0.requestKeyframe() }
        try #require(refreshed.first?.isKeyframe == true)
        let host = KeyframeCounter()
        let pipeline = RemoteDecodePipeline(source: host) { _ in }
        #expect(await pipeline.decode(first[0]) == .decoded)
        // Frame 1 is lost: frame 2 references it and must not be shown.
        #expect(await pipeline.decode(first[2]) == .gap)
        #expect(host.requests == 1)
        #expect(await pipeline.decode(refreshed[0]) == .decoded)
        let stats = await pipeline.stats
        #expect(stats.decoded == 2)
        #expect(stats.gaps == 1)
        #expect(stats.keyframeRequests == 1)
    }

    @Test func garbageAsksForAKeyframeInsteadOfShowingIt() async {
        let host = KeyframeCounter()
        let pipeline = RemoteDecodePipeline(source: host) { _ in Issue.record("garbage was delivered") }
        let junk = RemoteAccessUnit(frame: 0, flags: .keyframe, tCaptureMicros: 0, data: Data([0, 0, 1, 0x65, 1, 2, 3]), codec: .h264)
        #expect(await pipeline.decode(junk) == .failed)
        #expect(host.requests == 1)
    }
}

/// A source that only counts keyframe requests.
private nonisolated final class KeyframeCounter: RemoteViewStreamSource {
    private let count = Mutex(0)
    var requests: Int { count.withLock { $0 } }

    func accessUnits() -> AsyncStream<RemoteAccessUnit> { AsyncStream.makeStream(of: RemoteAccessUnit.self, bufferingPolicy: .bufferingNewest(1)).stream }
    func statusUpdates() -> AsyncStream<RemoteViewStatus> { AsyncStream.makeStream(of: RemoteViewStatus.self, bufferingPolicy: .bufferingNewest(1)).stream }
    func cursorUpdates() -> AsyncStream<RemoteCursorState> { AsyncStream.makeStream(of: RemoteCursorState.self, bufferingPolicy: .bufferingNewest(1)).stream }
    func requestKeyframe() { count.withLock { $0 += 1 } }
}
