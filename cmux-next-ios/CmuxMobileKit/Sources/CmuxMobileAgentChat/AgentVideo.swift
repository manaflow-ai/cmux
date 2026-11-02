import Foundation

/// An attached video as the agent gets it (the Mac's, webviews composer/videoPrompt.ts): its
/// link, then a note naming it with its length, size and each frame's time, then each frame
/// as a label and a JPEG image block. An agent can't watch a video; the frames are what it
/// looks at. The note and the frames are for the agent only: the sent bubble shows the video.
public struct AgentVideo: Hashable, Sendable {
    public struct Frame: Hashable, Sendable {
        public var atMs: Int
        /// JPEG bytes.
        public var jpeg: Data

        public init(atMs: Int, jpeg: Data) {
            self.atMs = atMs
            self.jpeg = jpeg
        }
    }

    public var durationMs: Int
    public var width: Int
    public var height: Int
    public var frames: [Frame]

    public init(durationMs: Int, width: Int, height: Int, frames: [Frame]) {
        self.durationMs = durationMs
        self.width = width
        self.height = height
        self.frames = frames
    }

    /// The movies the Mac reads (AgentPaneReplyPaths.videoExtensions).
    public static func isVideoName(_ name: String) -> Bool {
        ["mov", "mp4", "m4v"].contains((name as NSString).pathExtension.lowercased())
    }

    /// A time in a video as the note and each frame's name say it: `m:ss.d`, or `h:mm:ss.d`.
    public static func frameTime(_ ms: Int) -> String {
        let tenths = max(0, Int((Double(ms) / 100).rounded()))
        let h = tenths / 36_000
        let m = (tenths % 36_000) / 600
        let s = Double(tenths % 600) / 10
        let ss = String(format: "%04.1f", s)
        return h > 0 ? "\(h):\(String(format: "%02d", m)):\(ss)" : "\(m):\(ss)"
    }

    /// The video's length as the note says it: `m:ss`, or `h:mm:ss`.
    static func length(_ ms: Int) -> String {
        let total = max(1, Int((Double(ms) / 1000).rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = String(format: "%02d", total % 60)
        return h > 0 ? "\(h):\(String(format: "%02d", m)):\(s)" : "\(m):\(s)"
    }

    /// A frame's image block name: the video's name and the frame's time.
    public static func frameName(_ video: String, atMs: Int) -> String {
        "\(video) frame at \(frameTime(atMs))"
    }

    /// The note that comes before a video's frames (one line, so a bubble can leave it out).
    public func framesNote(name: String) -> String {
        let at = frames.map { Self.frameTime($0.atMs) }.joined(separator: ", ")
        return "Frames from the video \(name) (\(Self.length(durationMs)), \(width)×\(height)), in order, at: \(at)."
    }

    /// Whether `name` is a video frame's image name (`frameName`).
    public static func isFrameName(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.range(of: #"\.(mov|mp4|m4v) frame at \d+(:\d{2}){1,2}\.\d$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `text` without the frames notes and frame labels a prompt carried for the agent, given the
    /// names of the prompt's images: only those of a video whose frames the prompt carries.
    public static func withoutFrameText(_ text: String, imageNames: [String?]) -> String {
        let frames = imageNames.compactMap { $0 }.filter { isFrameName($0) }
        guard !frames.isEmpty else { return text }
        let labels = Set(frames + frames.map { "\($0) (new scene)" })
        let notes = Set(frames.map { name -> String in
            let video = name.replacingOccurrences(of: #" frame at [\d:.]+$"#, with: "", options: .regularExpression)
            return "Frames from the video \(video) ("
        })
        let lines = text.components(separatedBy: "\n")
        let kept = lines.filter { line in
            !labels.contains(line) && !(line.hasPrefix("Frames from the video ") && notes.contains { line.hasPrefix($0) })
        }
        guard kept.count != lines.count else { return text }
        return kept.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .newlines)
    }
}
