import AVFoundation
import CmuxNextCompat
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A video's length, size, poster and key frames (`video.info`), for its chip in the composer, its
/// sent bubble and the agent, which cannot watch a video but can look at its frames. Leo,
/// 2026-10-25: "also why dont we have previews of videos we should". The page cannot decode a
/// video itself, so AVFoundation reads it here, off the main actor: only the frames it asks for,
/// never the whole file.
nonisolated enum AgentPaneVideoInfo {
    /// The longest side of the poster, the chip's and the bubble's tile.
    static let posterSide = 320
    /// The longest side of a key frame: as large as a model reads a picture well, without
    /// sending a 4K frame's bytes.
    static let frameSide = 1024
    /// How many key frames a video gives.
    static let frameCount = 4
    /// How far from the asked time a frame may be: the nearest sync frame within it is fast to
    /// decode, and a key frame does not need its exact time.
    static let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
    /// JPEG quality of the poster and frames.
    static let quality = 0.8

    struct Frame: Equatable, Sendable {
        /// Where in the video the frame is, in milliseconds.
        var atMs: Int
        var jpeg: Data
    }

    struct Info: Equatable, Sendable {
        var durationMs: Int
        /// The size the video shows at, after its track's rotation.
        var width: Int
        var height: Int
        /// The first key frame, at most ``posterSide`` on its longest side.
        var poster: Data
        var frames: [Frame]

        /// The page's answer: the poster as a `data:` URL, each frame's JPEG as base64 for an
        /// image block.
        var reply: [String: Any] {
            [
                "durationMs": durationMs, "width": width, "height": height,
                "poster": "data:image/jpeg;base64," + poster.base64EncodedString(),
                "frames": frames.map { ["atMs": $0.atMs, "data": $0.jpeg.base64EncodedString()] },
            ]
        }
    }

    /// The times of `count` key frames of a video `duration` seconds long: the middle of each of
    /// `count` equal parts, so neither the first frame (often black) nor the very last.
    static func frameTimes(duration: Double, count: Int) -> [Double] {
        guard duration.isFinite, duration > 0, count > 0 else { return [] }
        return (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
    }

    /// The video at `file` (a regular file), or nil when it is not one AVFoundation can show: no
    /// video track, no length, or no frame it can decode.
    @concurrent static func read(_ file: URL) async -> Info? {
        guard (try? file.blockingResourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        let asset = AVURLAsset(url: file)
        guard let duration = try? await asset.load(.duration), let track = try? await asset.loadTracks(withMediaType: .video).first,
              let geometry = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let seconds = duration.seconds
        let shown = CGRect(origin: .zero, size: geometry.0).applying(geometry.1).size
        let width = Int(abs(shown.width).rounded()), height = Int(abs(shown.height).rounded())
        guard seconds.isFinite, seconds > 0, width > 0, height > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: frameSide, height: frameSide)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var frames: [Frame] = []
        var first: CGImage?
        for time in frameTimes(duration: seconds, count: frameCount) {
            guard let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)),
                  let data = jpeg(frame.image) else { continue }
            first = first ?? frame.image
            let at = frame.actualTime.seconds.isFinite ? frame.actualTime.seconds : time
            frames.append(Frame(atMs: Int((min(max(at, 0), seconds) * 1000).rounded()), jpeg: data))
        }
        guard let first, let poster = scaled(first, toFit: posterSide).flatMap(jpeg) else { return nil }
        return Info(durationMs: Int((seconds * 1000).rounded()), width: width, height: height, poster: poster, frames: frames)
    }

    /// `image` as JPEG at ``quality``.
    static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// `image` drawn at most `side` on its longest side; the image itself when it is already that small.
    static func scaled(_ image: CGImage, toFit side: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > side else { return image }
        let scale = Double(side) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

extension AgentPaneModel {
    /// The video file `src` (a path or `file://` URL) names, when the pane may show it: a chat on
    /// this Mac, a `.mov`, `.mp4` or `.m4v` that exists inside the chat's roots, its folder, `/tmp`
    /// or home (where a screen recording lands), and not on the deny list. A chat on another
    /// machine names its own files: this Mac's are never read for it.
    func videoFile(_ src: String) -> URL? {
        guard !remoteChat, let resolved = replyPaths().resolveVideo(src), resolved.place == .root, !resolved.isFolder else { return nil }
        return URL(fileURLWithPath: resolved.path, isDirectory: false)
    }

    /// `video.info {src}`: the video's length, size, poster and key frames (``AgentPaneVideoInfo``).
    func videoInfo(_ src: String) async -> [String: Any] {
        guard let file = videoFile(src), let info = await AgentPaneVideoInfo.read(file) else { return Self.replyFailure(.mediaRefused) }
        return AgentPaneReply.success(info.reply)
    }

    /// `video.quickLook {src}`: plays the video in Quick Look, on the person's click.
    func quickLookVideo(_ src: String) -> [String: Any] {
        guard let file = videoFile(src) else { return Self.replyFailure(.mediaRefused) }
        guard transport.gestures.consume() else { return Self.replyFailure(.gestureRequired) }
        replyLinks.quickLookFile(file)
        return AgentPaneReply.success()
    }
}
