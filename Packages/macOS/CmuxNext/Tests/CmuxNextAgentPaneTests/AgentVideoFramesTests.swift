import AVFoundation
@testable import CmuxNextAgentPane
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing

/// Leo, 2026-11-01: "i feel like cmux-next should give u better tools to deal with this kind of
/// thing". The `video_frames` agent tool's decoder (``AgentVideoFrames``, `video.frames`): the
/// numbers, frames at the asked times and size, grey samples for scene changes, and a byte budget.
@Suite(.serialized)
struct AgentVideoFramesTests {
    /// A 2 s H.264 movie of `width`×`height` at 5 frames a second: red for its first second,
    /// blue for the next.
    private static func movie(width: Int, height: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-frames-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for index in 0..<10 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let red = index < 5
            for row in 0..<height {
                let line = base + row * CVPixelBufferGetBytesPerRow(pixels)
                for column in 0..<width {
                    line[column * 4] = red ? 0 : 255
                    line[column * 4 + 1] = 0
                    line[column * 4 + 2] = red ? 255 : 0
                    line[column * 4 + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 5)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }

    private static func image(_ base64: String) throws -> CGImage {
        let jpeg = try #require(Data(base64Encoded: base64))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private static func isRed(_ image: CGImage) throws -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return pixel[0] > pixel[2]
    }

    @Test func noTimesGiveTheNumbersOnly() async throws {
        let clip = try await Self.movie(width: 640, height: 360)
        defer { try? FileManager.default.removeItem(at: clip) }
        let report = try #require(await AgentVideoFrames.read(clip, times: [], side: 1280, format: .jpeg, tolerance: 0, maxBytes: 1 << 20))
        #expect(abs(report.durationMs - 2000) <= 250, "\(report.durationMs)")
        #expect(report.width == 640 && report.height == 360)
        #expect(abs(report.fps - 5) < 1, "\(report.fps)")
        #expect(!report.hasAudio)
        #expect(report.frames.isEmpty && report.dropped == 0)
    }

    @Test func framesAreAtTheAskedTimesAndSize() async throws {
        let clip = try await Self.movie(width: 640, height: 360)
        defer { try? FileManager.default.removeItem(at: clip) }
        let report = try #require(await AgentVideoFrames.read(clip, times: [0.2, 1.6], side: 320, format: .jpeg, tolerance: 0, maxBytes: 1 << 20))
        #expect(report.frames.map(\.atMs) == [200, 1600])
        let frames = try report.frames.map { try Self.image($0.data) }
        #expect(frames.allSatisfy { $0.width == 320 && $0.height == 180 })
        #expect(try Self.isRed(frames[0]))
        #expect(try !Self.isRed(frames[1]))
        // A frame is never made larger than the video.
        let large = try #require(await AgentVideoFrames.read(clip, times: [0.2], side: 2048, format: .jpeg, tolerance: 0, maxBytes: 1 << 20))
        #expect(try Self.image(large.frames[0].data).width == 640)
    }

    @Test func greySamplesAreSideBySideBytesThatChangeWithThePicture() async throws {
        let clip = try await Self.movie(width: 640, height: 360)
        defer { try? FileManager.default.removeItem(at: clip) }
        let report = try #require(await AgentVideoFrames.read(clip, times: [0.2, 0.6, 1.4], side: 8, format: .luma, tolerance: 0, maxBytes: 1 << 20))
        let samples = try report.frames.map { try #require(Data(base64Encoded: $0.data)) }
        #expect(samples.allSatisfy { $0.count == 64 })
        let change = { (a: Data, b: Data) in zip(a, b).map { abs(Int($0) - Int($1)) }.reduce(0, +) / a.count }
        #expect(change(samples[0], samples[1]) < 2, "red to red")
        #expect(change(samples[1], samples[2]) > 10, "red to blue")
    }

    @Test func framesStopAtTheByteBudgetAndSayHowManyAreLeftOut() async throws {
        let clip = try await Self.movie(width: 640, height: 360)
        defer { try? FileManager.default.removeItem(at: clip) }
        let one = try #require(await AgentVideoFrames.read(clip, times: [0.2], side: 640, format: .jpeg, tolerance: 0, maxBytes: 1 << 20))
        let size = one.frames[0].data.utf8.count
        let report = try #require(await AgentVideoFrames.read(clip, times: [0.2, 0.4, 0.6, 0.8], side: 640, format: .jpeg, tolerance: 0,
                                                              maxBytes: size * 2 + size / 2))
        #expect(report.frames.count == 2)
        #expect(report.dropped == 2)
    }

    @Test func aFileThatIsNotAVideoGivesNothing() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-video-\(UUID().uuidString).mp4")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(await AgentVideoFrames.read(file, times: [0], side: 320, format: .jpeg, tolerance: 0, maxBytes: 1 << 20) == nil)
    }
}
