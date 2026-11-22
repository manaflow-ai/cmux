public import CmuxNextControl
import CmuxNextSettings
import Darwin
import Foundation

/// `video.frames` on the app control socket: a video file's length, size, frame rate, audio
/// and its frames at the times asked (``AgentVideoFrames``), for the `video_info` and
/// `video_frames` agent tools (cmux-tui `cli/mcp/video_tools.rs`), so an agent looks into a
/// video without ffmpeg.
///
/// Params: `path` (absolute), `dev` and `ino` (the file as the caller sees it, decimal
/// strings), `times` (seconds; empty for only the numbers), `side` (longest side, default
/// 1280), `format` (`jpeg` or `luma`), `tolerance` (seconds), `maxBytes` (the frames' base64
/// budget). A path whose file is not the caller's (a chat whose server runs on another machine
/// names its own files) is `not_found`: this Mac's file of that name is never read for it.
public nonisolated struct VideoControl: Sendable {
    /// Up to 64 small frames or 16 large ones from a long file.
    static let deadline: Duration = .seconds(60)
    /// The largest answer: under the CLI's 16 MiB response cap.
    static let maximumBytes = 12 << 20

    public init() {}

    /// The App's control service registers these (`AppControl`).
    public func methods() -> [ControlMethod] {
        [.async("video.frames") { call in try await Self.run(call.params) }.withDeadline(.fixed(Self.deadline))]
    }

    static func run(_ params: [String: JSONValue]) async throws -> JSONValue {
        guard let path = params["path"]?.stringValue, path.hasPrefix("/") else {
            throw ControlError.invalidParams("video.frames needs path: an absolute file path")
        }
        guard let dev = params["dev"]?.stringValue, let ino = params["ino"]?.stringValue else {
            throw ControlError.invalidParams("video.frames needs dev and ino: the file as the caller sees it")
        }
        var info = stat()
        guard stat(path, &info) == 0, String(UInt64(bitPattern: Int64(info.st_dev))) == dev, String(info.st_ino) == ino else {
            throw ControlError(code: "not_found", message: "\(path) is not a file on the Mac the cmux app runs on; a chat on another machine reads its videos with that machine's own tools")
        }
        let times: [Double] = try (params["times"]?.arrayValue ?? []).map { value in
            guard let seconds = value.doubleValue, seconds.isFinite, seconds >= 0 else {
                throw ControlError.invalidParams("video.frames times are seconds, 0 or more")
            }
            return seconds
        }
        guard times.count <= AgentVideoFrames.maximumTimes else {
            throw ControlError.invalidParams("video.frames takes at most \(AgentVideoFrames.maximumTimes) times")
        }
        let format: AgentVideoFrames.Format = try params["format"]?.stringValue.map { raw in
            guard let parsed = AgentVideoFrames.Format(rawValue: raw) else { throw ControlError.invalidParams("video.frames format is jpeg or luma") }
            return parsed
        } ?? .jpeg
        let side = params["side"]?.intValue ?? 1280
        guard AgentVideoFrames.sides.contains(side) else {
            throw ControlError.invalidParams("video.frames side is \(AgentVideoFrames.sides.lowerBound) to \(AgentVideoFrames.sides.upperBound)")
        }
        let budget = min(max(params["maxBytes"]?.intValue ?? maximumBytes, 0), maximumBytes)
        guard let report = await AgentVideoFrames.read(URL(fileURLWithPath: path), times: times, side: side, format: format,
                                                       tolerance: params["tolerance"]?.doubleValue ?? 0.5, maxBytes: budget) else {
            throw ControlError(code: "unsupported", message: "\(path) is not a video this Mac can decode (no video track, no length, or no frame)")
        }
        return .object([
            "durationMs": JSONValue(report.durationMs), "width": JSONValue(report.width), "height": JSONValue(report.height),
            "fps": .number(report.fps), "hasAudio": .bool(report.hasAudio), "dropped": JSONValue(report.dropped),
            "frames": .array(report.frames.map { frame in JSONValue.object(["atMs": JSONValue(frame.atMs), "data": .string(frame.data)]) }),
        ])
    }
}
