import Foundation

/// An attached video as the agent gets it (the Mac's, webviews composer/videoPrompt.ts): its
/// link, then a note naming it with its length, size and each frame's time, then each frame
/// as a label and a JPEG image block. An agent can't watch a video; the frames are what it
/// looks at. The note and the frames are for the agent only: the sent bubble shows the video.
public struct AgentVideo: Hashable, Sendable, Codable {
    public struct Frame: Hashable, Sendable, Codable {
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

/// The videos a recorded prompt sent, read back from what it sent the agent (Leo, 2026-10-25:
/// "also why dont we have previews of videos we should"; 2026-11-04: "i can neither preview a vid
/// in place nor have it pop up anymore :("), as the Mac's bubble does (webviews
/// conversation/sentVideos.ts): each video's frames note gives its name, length and size, its link
/// its path on the Mac, and its first frame image its poster. acpmux keeps all three through a
/// reload, so a video this phone sent before a relaunch, or the Mac sent, comes back as its tile.
///
/// Swift, not the Rust mobile core: no crate on the phone parses acpmux records (the phone reads
/// them in `AcpmuxRecords`), and this sits beside the note's writer (`framesNote`).
extension AgentVideo {
    /// A file link a recorded prompt sent: its name and its path on the Mac.
    public struct SentLink: Hashable, Sendable {
        public var name: String
        public var path: String

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    /// An image a recorded prompt sent, by acpmux's id.
    public struct SentImage: Hashable, Sendable {
        public var id: String
        public var name: String?

        public init(id: String, name: String?) {
            self.id = id
            self.name = name
        }
    }

    /// The id prefix of a video a recorded prompt links (its path follows).
    public static let recordedVideoPrefix = "acpmux-video:"

    /// The videos a prompt sent, in the order their notes come; then a video linked with no note
    /// (its frames were never read, or the agent takes no images) as a file chip, as on the Mac.
    /// `lines`: the prompt's text lines, notes included; `links`: its file links; `images`: its
    /// recorded images.
    public static func sentVideos(lines: [String], links: [SentLink], images: [SentImage]) -> [AgentAttachment] {
        var seen = Set<String>()
        var videos: [AgentAttachment] = []
        for line in lines {
            guard let note = line.prefixMatch(of: #/Frames from the video (.+) \((\d+(?::\d{2}){1,2}), (\d+)×(\d+)\), in order, at: /#)
            else { continue }
            let name = String(note.output.1)
            // A length or size no video has (a person's own text that reads like a note) leaves the
            // link to the chip below, never a trap in the arithmetic.
            guard !seen.contains(name), let link = links.first(where: { $0.name == name }),
                  let width = Int(note.output.3), let height = Int(note.output.4),
                  let durationMs = lengthMs(String(note.output.2)) else { continue }
            seen.insert(name)
            let poster = images.first { $0.name?.hasPrefix("\(name) frame at ") == true }
            videos.append(AgentAttachment(
                id: recordedVideoPrefix + link.path, kind: .file, name: name,
                video: AgentVideo(durationMs: durationMs, width: width, height: height, frames: []),
                macPath: link.path, posterID: poster?.id))
        }
        for link in links where isVideoName(link.name) && !seen.contains(link.name) {
            seen.insert(link.name)
            videos.append(AgentAttachment(id: recordedVideoPrefix + link.path, kind: .file, name: link.name, macPath: link.path))
        }
        return videos
    }

    /// The longest length a note may say: past it the note is not one this app wrote.
    static let maxLengthMs = 10_000 * 3_600_000

    /// Milliseconds of a length as the note says it (`m:ss` or `h:mm:ss`); nil for a part that is
    /// not a number or a length past ``maxLengthMs``, so no arithmetic here can overflow.
    static func lengthMs(_ text: String) -> Int? {
        var seconds = 0
        for part in text.split(separator: ":") {
            guard let value = Int(part), value >= 0, seconds <= maxLengthMs / 60_000 else { return nil }
            seconds = seconds * 60 + min(value, maxLengthMs)
            guard seconds <= maxLengthMs / 1000 else { return nil }
        }
        return seconds * 1000
    }
}

extension AgentAttachment {
    /// The picture a sent bubble draws for this attachment: an image itself; a video its first
    /// frame (this phone's own bytes, else the recorded poster the Mac reads); nil otherwise.
    public var picture: AgentAttachment? {
        if kind == .image { return self }
        guard let video else { return nil }
        if let frame = video.frames.first {
            return AgentAttachment(id: id + ":poster", kind: .image, name: name, data: frame.jpeg)
        }
        guard let posterID else { return nil }
        return .recordedImage(id: posterID, name: name)
    }
}
