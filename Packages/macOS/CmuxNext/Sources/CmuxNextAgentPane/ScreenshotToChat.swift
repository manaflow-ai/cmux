import CmuxNextCompat
public import CmuxNextSettings
public import Foundation
import os

/// Capture Screenshot to Chat (`palette.captureScreenshotToChat`, Leo, 2026-11-08, ask-a862e90c70, on
/// screenshots that could not reach a chat from another app): the system's region pick
/// (`screencapture -i`, as + > Attach Screenshot… runs it), written as a PNG into a fresh folder under
/// Chat Uploads (``ChatUploadFolders``, whose expiry covers it). The App then hands the file to its one
/// route into a chat's composer (`ExternalOpenController.attachToChat`). The pick's UI and the Screen
/// Recording permission are macOS's; Esc takes nothing and leaves no file.
public nonisolated struct ScreenshotToChat: Sendable {
    /// The user-facing system region pick.
    public enum Pick: Equatable, Sendable {
        case picker
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
        let result = await AgentPaneCapture.capture(window: false, to: file, executable: executable)
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
    @MainActor public static var failedMessage: String { AgentPaneModel.captureFailedMessage }

    /// `chat.capture.toChat`'s answer for an Esc in the pick.
    public static let cancelledAnswer: JSONValue = .object(["cancelled": .bool(true)])

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
