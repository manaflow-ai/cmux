import CmuxNextRemoteView
import CoreGraphics
import CoreVideo
import Testing

/// Decoded frames and the mock host's encoder cross threads through checked Sendable values and a
/// Mutex (p10-stability-056). Run under TSan: the encoder runs on the mock's queue, its output on a
/// VideoToolbox thread, the decode on the pipeline actor.
@Suite struct RemoteFrameHandoffTests {
    @Test func aDecodedFrameKeepsItsPixelBufferAcrossTasks() async throws {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 8, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &made)
        let buffer = try #require(made)
        let frame = RemoteDecodedFrame(pixelBuffer: buffer, frame: 7, tCaptureMicros: 1, decodedAtNanos: 2)

        let size = await Task.detached { frame.pixelSize }.value

        #expect(frame.pixelBuffer === buffer)
        #expect(size == CGSize(width: 16, height: 8))
        #expect(frame.frame == 7)
    }

    #if DEBUG
    @Test(.timeLimit(.minutes(1))) func mockHostFramesDecodeInOrder() async throws {
        let source = MockRemoteStreamSource(width: 320, height: 200)
        // A host without a VideoToolbox encoder (some VMs) has nothing to stream.
        guard source.canEncode else { return }
        let (frames, sink) = AsyncStream.makeStream(of: RemoteDecodedFrame.self)
        let pipeline = RemoteDecodePipeline(source: source, deliver: { sink.yield($0) })
        let units = source.accessUnits()

        for _ in 0..<3 { source.damage() }
        var outcomes: [RemoteDecodePipeline.Outcome] = []
        for await unit in units {
            outcomes.append(await pipeline.decode(unit))
            if outcomes.count == 3 { break }
        }
        sink.finish()
        var shown: [UInt32] = []
        for await frame in frames { shown.append(frame.frame) }

        #expect(outcomes == [.decoded, .decoded, .decoded])
        #expect(shown == [0, 1, 2])
    }
    #endif
}
