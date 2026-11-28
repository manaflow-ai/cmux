import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import CmuxNextRemoteView
import Testing

/// The peerless viewer stream: a recorded movie replays as access units the viewer's own
/// decode pipeline decodes, with no host (goal screen-share-viewer-present).
@Suite struct RemoteMovieReplaySourceTests {
    @Test func startsAtTheFirstKeyframeAndRebasesTime() throws {
        let samples = [
            RemoteMovieReplaySource.Sample(data: Data([1]), keyframe: false, seconds: 0.5),
            RemoteMovieReplaySource.Sample(data: Data([2]), keyframe: true, seconds: 1.0),
            RemoteMovieReplaySource.Sample(data: Data([3]), keyframe: false, seconds: 1.5),
        ]
        let source = try RemoteMovieReplaySource(codec: .h264, samples: samples, width: 8, height: 8)
        #expect(source.samples.map(\.data) == [Data([2]), Data([3])])
        #expect(source.samples.map(\.seconds) == [0, 0.5])
        #expect(source.period == 1.0)
    }

    @Test func aFileWithNoKeyframeIsRefused() {
        let samples = [RemoteMovieReplaySource.Sample(data: Data([1]), keyframe: false, seconds: 0)]
        #expect(throws: RemoteMovieReplaySource.ReplayError.noKeyframe) {
            try RemoteMovieReplaySource(codec: .h264, samples: samples, width: 8, height: 8)
        }
    }

    @Test func aRecordedMovieDecodesThroughTheViewerPipeline() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = 20
        try await Self.writeMovie(to: url, frames: frames)

        let source = try await RemoteMovieReplaySource.load(url, loops: 2, rate: 20)
        #expect(source.codec == .h264)
        #expect(source.width == 160 && source.height == 96)
        #expect(source.samples.count == frames)
        #expect(source.samples.first?.keyframe == true)

        var units: [RemoteAccessUnit] = []
        for await unit in source.accessUnits() { units.append(unit) }
        #expect(units.map(\.frame) == (0 ..< UInt32(frames * 2)).map { $0 })
        #expect(units.allSatisfy { $0.releasedAtNanos > 0 })
        #expect(units[0].isKeyframe && units[frames].isKeyframe)
        #expect(RemoteAnnexB().parse(units[0].data, codec: .h264).parameterSets.count == 2)

        // The same decoder a live session uses: every unit decodes, none waits for a keyframe.
        let pipeline = RemoteDecodePipeline(source: source, deliver: { _ in })
        for unit in units { await pipeline.decode(unit) }
        let stats = await pipeline.stats
        #expect(stats.decoded == frames * 2)
        #expect(stats.gaps == 0 && stats.decodeErrors == 0 && stats.skipped == 0)
        #expect(source.keyframeRequests == 0)
    }

    /// An H.264 movie of `frames` flat frames, 30 per second, with a keyframe every 10.
    private static func writeMovie(to url: URL, frames: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 96,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: 10,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 96,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0 ..< frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                memset(base, Int32(index * 12 % 256), CVPixelBufferGetDataSize(pixels))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
