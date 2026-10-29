import CmuxNextRemoteView
import CoreGraphics
import CoreVideo
import Testing

// The mock host exists in development builds only.
#if DEBUG
/// Decoded frames cross threads as checked Sendable values over one CoreVideo hand-off wrapper, and
/// the mock host's encoder is an actor on its own serial queue. Run under TSan:
/// the encoder runs on the mock's queue, its output on a VideoToolbox thread, the decode on the
/// pipeline actor, and the readers on the cooperative pool.
@Suite struct RemoteFrameHandoffTests {
    @Test(.timeLimit(.minutes(1))) func mockHostFramesDecodeInOrder() async throws {
        let source = MockRemoteStreamSource(width: 320, height: 200)
        try #require(source.canEncode, "VideoToolbox has no H.264 encoder here")
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

    /// Eight tasks read each decoded frame's pixel buffer at the same time, while the mock host
    /// paints and encodes the next frame and the pipeline decodes it.
    @Test(.timeLimit(.minutes(1))) func manyTasksReadEachFrameWhileTheNextOneDecodes() async throws {
        let source = MockRemoteStreamSource(width: 320, height: 200)
        try #require(source.canEncode, "VideoToolbox has no H.264 encoder here")
        let (frames, sink) = AsyncStream.makeStream(of: RemoteDecodedFrame.self)
        let pipeline = RemoteDecodePipeline(source: source, deliver: { sink.yield($0) })
        let units = source.accessUnits()
        let frameCount = 12
        let readers = 8

        let (shown, agreeing) = await withTaskGroup(of: Bool?.self, returning: ([UInt32], Int).self) { group in
            group.addTask {
                var decoded = 0
                source.damage()
                for await unit in units {
                    _ = await pipeline.decode(unit)
                    decoded += 1
                    if decoded == frameCount { break }
                    // The next frame encodes while this one's readers run.
                    source.damage()
                }
                sink.finish()
                return nil
            }
            var shown: [UInt32] = []
            for await frame in frames {
                shown.append(frame.frame)
                let size = frame.pixelSize
                for _ in 0..<readers {
                    group.addTask {
                        frame.pixelSize == size && CVPixelBufferGetPlaneCount(frame.pixelBuffer) == 2
                    }
                }
            }
            var agreeing = 0
            for await read in group where read == true { agreeing += 1 }
            return (shown, agreeing)
        }

        #expect(shown == Array(0..<UInt32(frameCount)))
        #expect(agreeing == frameCount * readers, "a reader saw another size or plane count than the decoder made")
    }
}
#endif
