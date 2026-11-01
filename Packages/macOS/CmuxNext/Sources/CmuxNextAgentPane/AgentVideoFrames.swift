import AVFoundation
import CoreGraphics
import Foundation

/// Frames of a video file at the times an agent asks for, for the `video_info` and
/// `video_frames` agent tools (`cmux mcp`, cmux-tui `video_tools.rs`), through the app method
/// `video.frames` (CmuxNextApp `VideoControl`). Leo, 2026-11-01, after an agent had to
/// hand-write ffmpeg to see a 16 s recording: "i feel like cmux-next should give u better tools
/// to deal with this kind of thing". The server picks the times, the size and the budget and
/// finds the scene changes; this only decodes, with the composer's decoder settings
/// (``AgentPaneVideoInfo``): only the frames asked for, never the whole file, and a reference
/// movie's media in other files is refused.
public nonisolated enum AgentVideoFrames {
    /// How a frame comes back: a JPEG (``AgentPaneVideoInfo/jpeg(_:)``), or `side` by `side`
    /// 8-bit grey pixels, the samples the server compares to find scene changes.
    public enum Format: String, Sendable {
        case jpeg
        case luma
    }

    public struct Frame: Equatable, Sendable {
        /// Where in the video the frame is, in milliseconds.
        public var atMs: Int
        /// Its bytes, base64.
        public var data: String
    }

    public struct Report: Equatable, Sendable {
        public var durationMs: Int
        /// The size the video shows at, after its track's rotation.
        public var width: Int
        public var height: Int
        /// The video track's nominal frame rate (0 when the file does not say).
        public var fps: Double
        public var hasAudio: Bool
        public var frames: [Frame] = []
        /// Frames asked for and left out because the answer reached its byte budget.
        public var dropped = 0
    }

    /// The most times one request decodes (the server's scene samples).
    public static let maximumTimes = 64
    /// The sides a frame may be asked at.
    public static let sides = 8...2048

    /// The video at `file` and its frames at `times` (seconds), each at most `side` pixels on its
    /// longest side, within `tolerance` seconds of the time asked; frames stop once their base64
    /// passes `maxBytes`. Nil when the file is not a video AVFoundation can show.
    @concurrent public static func read(_ file: URL, times: [Double], side: Int, format: Format,
                                        tolerance: Double, maxBytes: Int) async -> Report? {
        guard AgentPaneVideoInfo.isRegularFile(file) else { return nil }
        let asset = AVURLAsset(url: file, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        guard let duration = try? await asset.load(.duration), let track = try? await asset.loadTracks(withMediaType: .video).first,
              let geometry = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let seconds = duration.seconds
        let shown = CGRect(origin: .zero, size: geometry.0).applying(geometry.1).size
        let width = Int(abs(shown.width).rounded()), height = Int(abs(shown.height).rounded())
        guard seconds.isFinite, seconds > 0, width > 0, height > 0 else { return nil }
        let fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        var report = Report(durationMs: Int((seconds * 1000).rounded()), width: width, height: height,
                            fps: fps.isFinite ? fps : 0, hasAudio: hasAudio)
        let times = Array(times.prefix(maximumTimes))
        guard !times.isEmpty else { return report }
        let side = min(max(side, sides.lowerBound), sides.upperBound)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // A grey sample is drawn small from a small decode; a JPEG is decoded at its size.
        let decodeSide = format == .jpeg ? side : max(side * 8, 64)
        generator.maximumSize = CGSize(width: decodeSide, height: decodeSide)
        let slack = CMTime(seconds: tolerance.isFinite ? max(0, tolerance) : 0, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack
        var used = 0
        for (index, time) in times.enumerated() {
            let asked = min(max(time.isFinite ? time : 0, 0), seconds)
            guard let frame = try? await generator.image(at: CMTime(seconds: asked, preferredTimescale: 600)),
                  let data = format == .jpeg ? AgentPaneVideoInfo.jpeg(frame.image) : luma(frame.image, side: side) else { continue }
            let encoded = data.base64EncodedString()
            guard used + encoded.utf8.count <= maxBytes else {
                report.dropped = times.count - index
                break
            }
            used += encoded.utf8.count
            let at = frame.actualTime.seconds.isFinite ? frame.actualTime.seconds : asked
            report.frames.append(Frame(atMs: Int((min(max(at, 0), seconds) * 1000).rounded()), data: encoded))
        }
        return report
    }

    /// `image` drawn into `side` by `side` 8-bit grey pixels (its aspect is not kept: the samples
    /// are only compared with each other).
    static func luma(_ image: CGImage, side: Int) -> Data? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let pixels = context.data else { return nil }
        return Data(bytes: pixels, count: side * side)
    }
}
