import AVFoundation
import CmuxFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum WindowRecordingWriterError: Error, Equatable, LocalizedError {
    case setup(String)
    case frame(String)
    case finish(String)
    case noFrames

    var errorDescription: String? {
        switch self {
        case let .setup(detail): "recorder setup failed: \(detail)"
        case let .frame(detail): "frame write failed: \(detail)"
        case let .finish(detail): "closing the recording failed: \(detail)"
        case .noFrames: "the recording captured no frames"
        }
    }
}

/// Writes one recording's frames to disk as they are captured.
///
/// Frames are never collected as bitmaps: a 30 second clip of a Retina window
/// is a couple of gigabytes of uncompressed frames, which is not something the
/// app may hold in memory for an agent. MP4 frames stream into AVFoundation;
/// GIF frames are staged as compressed images until their exact count is known.
///
/// Frames are timed by the moment they were captured rather than by their
/// index, so a clip plays back at the speed the window was really moving at
/// even when the sampler could not keep up with the requested rate.
protocol WindowRecordingFrameWriter: AnyObject {
    func append(_ image: CGImage, atOffsetSeconds offsetSeconds: Double) async throws
    func finish() async throws
}

/// H.264 in an mp4 container, through AVFoundation.
final class WindowRecordingMP4Writer: WindowRecordingFrameWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int
    private let framesPerSecond: Int
    private var didStart = false
    private var frameCount = 0
    // One timescale tick before zero, so the first frame may present at zero.
    private var lastOffsetSeconds = -1.0 / 600

    init(url: URL, width: Int, height: Int, framesPerSecond: Int) throws {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw WindowRecordingWriterError.setup(error.localizedDescription)
        }
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Self.bitRate(
                        width: width,
                        height: height,
                        framesPerSecond: framesPerSecond
                    ),
                    AVVideoMaxKeyFrameIntervalKey: max(1, framesPerSecond * 2),
                ],
            ]
        )
        // Frames arrive as fast as the sampler produces them, not on a live
        // clock, so the writer may take its time compressing them.
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(input) else {
            throw WindowRecordingWriterError.setup("the video input was rejected")
        }
        writer.add(input)
    }

    /// Roughly 0.1 bits per pixel per frame, clamped to a range that keeps a
    /// terminal clip readable without making a pull request attachment huge.
    private static func bitRate(width: Int, height: Int, framesPerSecond: Int) -> Int {
        let pixels = Double(width * height)
        let estimate = pixels * Double(framesPerSecond) * 0.1
        return Int(min(max(estimate, 600_000), 12_000_000))
    }

    private static let timescale: CMTimeScale = 600

    func append(_ image: CGImage, atOffsetSeconds offsetSeconds: Double) async throws {
        if !didStart {
            guard writer.startWriting() else {
                throw WindowRecordingWriterError.setup(
                    writer.error?.localizedDescription ?? "the writer refused to start"
                )
            }
            writer.startSession(atSourceTime: .zero)
            didStart = true
        }
        try await waitUntilReady()
        guard let buffer = makePixelBuffer(from: image) else {
            throw WindowRecordingWriterError.frame("could not allocate a pixel buffer")
        }
        // Presentation times have to keep increasing even if two samples land
        // in the same 1/600 second.
        let offset = max(offsetSeconds, lastOffsetSeconds + (1 / Double(Self.timescale)))
        lastOffsetSeconds = offset
        guard adaptor.append(
            buffer,
            withPresentationTime: CMTime(seconds: offset, preferredTimescale: Self.timescale)
        ) else {
            throw WindowRecordingWriterError.frame(
                writer.error?.localizedDescription ?? "the writer rejected a frame"
            )
        }
        frameCount += 1
    }

    /// The compressor applies backpressure between frames; wait for it rather
    /// than dropping frames, and give up if it stalls for good.
    private func waitUntilReady() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw WindowRecordingWriterError.frame(
                    writer.error?.localizedDescription ?? "the writer failed"
                )
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw WindowRecordingWriterError.frame("the video compressor stalled")
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(
                nil,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                [
                    kCVPixelBufferCGImageCompatibilityKey: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                ] as CFDictionary,
                &buffer
            )
        }
        guard let pixelBuffer = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                  data: base,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        )
        return pixelBuffer
    }

    func finish() async throws {
        guard didStart, frameCount > 0 else {
            // Cancelling a writer that never started raises an exception rather
            // than returning an error, so only cancel one that is writing.
            if writer.status == .writing {
                writer.cancelWriting()
            }
            throw WindowRecordingWriterError.noFrames
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status != .completed {
            throw WindowRecordingWriterError.finish(
                writer.error?.localizedDescription ?? "the writer did not complete"
            )
        }
    }
}

/// An animated gif, through ImageIO.
///
/// A gif carries a delay per frame rather than a frame rate, and a frame's delay
/// is only known once the next frame has been captured, so one frame is always
/// held back.
///
/// ImageIO requires the destination's declared image count to equal the number
/// appended. A recording does not know that count until it stops, so frames are
/// staged on disk as PNGs and the destination is created in `finish`.
final class WindowRecordingGIFWriter: WindowRecordingFrameWriter {
    private let url: URL
    private let frameDirectory: URL
    private let nominalDelaySeconds: Double
    private let stagedByteLimit: Int64
    private var pending: (image: CGImage, offsetSeconds: Double)?
    private var frames: [(url: URL, delaySeconds: Double)] = []
    private var stagedBytes: Int64 = 0

    /// Browsers clamp very short gif delays to a tenth of a second; staying at
    /// or above two hundredths keeps playback predictable.
    private static let delayRange = 0.02...10.0
    /// A GIF stages compressed PNG frames before finalization. Bound that
    /// temporary disk footprint independently of the recording duration.
    static let maximumStagedBytes: Int64 = 256 * 1024 * 1024

    init(
        url: URL,
        framesPerSecond: Int,
        stagedByteLimit: Int64 = WindowRecordingGIFWriter.maximumStagedBytes
    ) throws {
        self.url = url
        self.stagedByteLimit = max(1, stagedByteLimit)
        frameDirectory = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).frames-\(UUID().uuidString.lowercased())"
        )
        do {
            try FileManager.default.createDirectory(
                at: frameDirectory,
                withIntermediateDirectories: false
            )
        } catch {
            throw WindowRecordingWriterError.setup(
                "could not stage gif frames at \(frameDirectory.path): \(error.localizedDescription)"
            )
        }
        nominalDelaySeconds = 1 / Double(max(1, framesPerSecond))
    }

    deinit {
        try? FileManager.default.removeItem(at: frameDirectory)
    }

    func append(_ image: CGImage, atOffsetSeconds offsetSeconds: Double) async throws {
        if let pending {
            try add(pending.image, delaySeconds: offsetSeconds - pending.offsetSeconds)
        }
        pending = (image, offsetSeconds)
    }

    private func add(_ image: CGImage, delaySeconds: Double) throws {
        guard stagedBytes < stagedByteLimit else {
            throw WindowRecordingWriterError.frame(
                "gif staging exceeded \(stagedByteLimit) bytes"
            )
        }
        let delay = min(
            max(delaySeconds.isFinite ? delaySeconds : nominalDelaySeconds, Self.delayRange.lowerBound),
            Self.delayRange.upperBound
        )
        let frameURL = frameDirectory.appendingPathComponent("\(frames.count).png")
        guard let destination = CGImageDestinationCreateWithURL(
            frameURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw WindowRecordingWriterError.frame("could not stage a gif frame")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: frameURL)
            throw WindowRecordingWriterError.frame("could not stage a gif frame")
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: frameURL.path)[.size])
            as? NSNumber else {
            try? FileManager.default.removeItem(at: frameURL)
            throw WindowRecordingWriterError.frame("could not measure a staged gif frame")
        }
        let frameBytes = size.int64Value
        guard frameBytes >= 0, frameBytes <= stagedByteLimit - stagedBytes else {
            try? FileManager.default.removeItem(at: frameURL)
            throw WindowRecordingWriterError.frame(
                "gif staging exceeded \(stagedByteLimit) bytes"
            )
        }
        stagedBytes += frameBytes
        frames.append((frameURL, delay))
    }

    func finish() async throws {
        if let pending {
            // The last frame is staged here, and a clip that ran out of staging
            // room cannot stage it. Dropping that one frame keeps the frames
            // before it, which is what a failed recording promises its caller;
            // a clip with nothing staged still reports why it has no frames.
            self.pending = nil
            do {
                try add(pending.image, delaySeconds: nominalDelaySeconds)
            } catch {
                guard !frames.isEmpty else { throw error }
            }
        }
        guard !frames.isEmpty else {
            throw WindowRecordingWriterError.noFrames
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw WindowRecordingWriterError.setup("could not create the gif at \(url.path)")
        }
        CGImageDestinationSetProperties(
            destination,
            [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: 0,
                ],
            ] as CFDictionary
        )
        for frame in frames {
            guard let source = CGImageSourceCreateWithURL(frame.url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw WindowRecordingWriterError.finish("a staged gif frame could not be decoded")
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: frame.delaySeconds,
                        kCGImagePropertyGIFUnclampedDelayTime: frame.delaySeconds,
                    ],
                ] as CFDictionary
            )
        }
        guard CGImageDestinationFinalize(destination) else {
            throw WindowRecordingWriterError.finish("the gif could not be finalized")
        }
        frames = []
        stagedBytes = 0
        try? FileManager.default.removeItem(at: frameDirectory)
    }
}
