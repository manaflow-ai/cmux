import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// The composer's + > Attach Screenshot… and Attach Window… (cx-ncc.71, the Codex app's Attach):
/// `composer.capture {mode: "screen" | "window"}`. After a click in the pane, macOS `screencapture`
/// runs its own region pick (`-i`) or window pick (`-iW`), so the selection UI and the Screen
/// Recording permission are the system's. It answers `{name, mimeType, data}` (base64 of the PNG
/// as `screencapture` wrote it) or `{cancelled: true}` when the person presses Esc.
///
/// Stub of the next commit's API, with this head's behaviour: it saves no original and answers no
/// `original`, so the page would have to upload the bytes back, on a gesture the capture used.
enum AgentPaneCapture {
    nonisolated static let tool = "/usr/sbin/screencapture"
    /// The preview's budget and longest side (unused until the fix makes a preview).
    nonisolated static let previewMaxBytes = 1536 * 1024
    nonisolated static let previewMaxSide = 1568
    /// The most bytes of the original staged at once (unused until the fix stages it).
    nonisolated static let chunkBytes = 512 * 1024

    /// Runs the pick into the file; false when it could not start (``capture(window:to:)``).
    typealias Pick = @Sendable (_ window: Bool, _ file: URL) async -> Bool

    /// `taken`: when the capture was taken (tests); now, once the pick ends, when nil.
    @MainActor static func reply(to mode: String?, in model: AgentPaneModel, taken: Date? = nil,
                                 pick: Pick = { window, file in await AgentPaneCapture.capture(window: window, to: file) }) async -> [String: Any] {
        guard let mode, mode == "screen" || mode == "window" else { return AgentPaneModel.unsupported("composer.capture") }
        // The screen goes to the agent: only a click in the pane starts a capture.
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-\(UUID().uuidString).png")
        var result = AgentPaneReply.success(["cancelled": true])
        if await pick(mode == "window", file) {
            let name = Self.name(taken: taken ?? Date())
            let png = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { (try? Data(blockingContentsOf: file)) ?? Data() }.value
            if !png.isEmpty { result = AgentPaneReply.success(["name": name, "mimeType": "image/png", "data": png.base64EncodedString()]) }
        }
        // task-owner: one delete of the capture's temporary file once it is answered; nothing waits for it
        Task.detached(priority: .utility) { try? FileManager.checked.removeItem(at: file) }
        return result
    }

    /// The capture's name for when it was `taken`, as macOS names its own (so two in one prompt differ).
    nonisolated static func name(taken: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Screenshot \(formatter.string(from: taken)).png"
    }

    /// Runs the pick; false when `screencapture` could not start. Its caller is the main actor: the spawn
    /// runs on AsyncProcess's own queue, and the wait holds no thread.
    nonisolated static func capture(window: Bool, to file: URL) async -> Bool {
        // -x: no shutter sound; -o: no window shadow.
        let arguments = (window ? ["-i", "-W", "-o"] : ["-i"]) + ["-x", "-t", "png", file.path]
        return (try? await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: tool), arguments))) != nil
    }
}
