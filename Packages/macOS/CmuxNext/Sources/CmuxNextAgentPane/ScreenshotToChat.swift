import CmuxNextCompat
public import CmuxNextSettings
public import Foundation
import os

/// Capture Screenshot to Chat (`palette.captureScreenshotToChat`, Leo, 2026-11-08, ask-a862e90c70, on
/// screenshots that could not reach a chat from another app): the system's region pick
/// (`screencapture -i`, as + > Attach Screenshot… runs it), or a given region with no pick
/// (`chat.capture.toChat {region}` for scripted walks, `screencapture -R`), written as a PNG into a
/// fresh folder under Chat Uploads (``ChatUploadFolders``, whose expiry covers it). The App then hands
/// the file to its one route into a chat's composer (`ExternalOpenController.attachToChat`). The pick's
/// UI and the Screen Recording permission are macOS's; Esc takes nothing and leaves no file.
public nonisolated struct ScreenshotToChat: Sendable {
    /// What to take: the system's region pick, or a region in global points from the top-left
    /// (`screencapture -R`'s x, y, width and height).
    public enum Pick: Equatable, Sendable {
        case picker
        case region(x: Int, y: Int, width: Int, height: Int)
    }

    /// What one capture produced.
    public enum Outcome: Equatable, Sendable {
        /// The PNG at `file`, `bytes` long.
        case taken(URL, bytes: Int)
        /// The person pressed Esc in the pick: nothing to attach.
        case cancelled
        /// `screencapture` could not start or ended with an error, in the system's words.
        case failed(String)
    }

    /// A `region` that is not four integers with a positive width and height.
    public struct BadRegion: Error, Equatable, Sendable {
        public let message: String
    }

    public let folders: ChatUploadFolders
    let executable: String
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.capture-to-chat")

    public init(folders: ChatUploadFolders) {
        self.init(folders: folders, executable: AgentPaneCapture.tool)
    }

    init(folders: ChatUploadFolders, executable: String) {
        self.folders = folders
        self.executable = executable
    }

    /// `chat.capture.toChat`'s params: `{"region": [x, y, w, h]}` takes that region with no pick, and
    /// none (or `{}`) runs the system's pick. Numbers are rounded to whole points.
    public static func pick(from params: JSONValue) throws(BadRegion) -> Pick {
        guard let region = params["region"], region != .null else { return .picker }
        guard case .array(let values) = region, values.count == 4 else {
            throw BadRegion(message: "region must be [x, y, width, height]")
        }
        let numbers = values.compactMap { $0.doubleValue }
        guard numbers.count == 4, numbers.allSatisfy(\.isFinite) else {
            throw BadRegion(message: "region must be four numbers")
        }
        let rounded = numbers.map { Int($0.rounded()) }
        guard rounded[2] > 0, rounded[3] > 0 else { throw BadRegion(message: "region needs a positive width and height") }
        return .region(x: rounded[0], y: rounded[1], width: rounded[2], height: rounded[3])
    }

    /// `screencapture`'s arguments for `pick`, writing `file`: -i the region pick, or -R the region;
    /// -x no shutter sound, -t png.
    static func arguments(for pick: Pick, to file: URL) -> [String] {
        switch pick {
        case .picker: ["-i", "-x", "-t", "png", file.path]
        case .region(let x, let y, let width, let height): ["-x", "-R\(x),\(y),\(width),\(height)", "-t", "png", file.path]
        }
    }

    /// Takes `pick` into `Screenshot <when>.png` in a fresh upload folder, off the main actor. An Esc
    /// (no file, or an empty one) or a failure leaves no folder behind.
    @concurrent public func take(_ pick: Pick, taken: Date = Date()) async -> Outcome {
        let folder = folders.freshUpload(session: nil)
        let file = folder.appending(path: "Screenshot \(Self.stamp(taken)).png")
        do {
            try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failed("could not make \(folder.lastPathComponent): \(error)")
        }
        let result = await AgentPaneCapture.capture(arguments: Self.arguments(for: pick, to: file), to: file, executable: executable)
        let bytes = (try? FileManager.checked.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        switch result {
        case .taken where bytes > 0:
            return .taken(file, bytes: bytes)
        case .taken:
            try? FileManager.checked.removeItem(at: folder)
            return .cancelled
        case .failed(let reason):
            Self.logger.error("capture to chat: screencapture failed: \(reason, privacy: .public)")
            try? FileManager.checked.removeItem(at: folder)
            return .failed(reason)
        }
    }

    /// What the person sees when the capture could not start or failed (no Screen Recording grant).
    public static var failedMessage: String { AgentPaneModel.captureFailedMessage }

    /// `chat.capture.toChat`'s answer: `{session, path, bytes}`, `session` the chat that took it
    /// (null for a chat that has not started yet, or one still opening).
    public static func answer(session: String?, file: URL, bytes: Int) -> JSONValue {
        .object(["session": session.map(JSONValue.string) ?? .null, "path": .string(file.path), "bytes": .number(Double(bytes))])
    }

    /// As macOS names its own screenshots, so two in one prompt differ.
    static func stamp(_ taken: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: taken)
    }
}
