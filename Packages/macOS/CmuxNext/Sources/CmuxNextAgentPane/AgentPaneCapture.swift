import CmuxNextWakeups
import Foundation

/// The composer's + > Attach Screenshot… and Attach Window… (cx-ncc.71, the Codex app's Attach):
/// `composer.capture {mode: "screen" | "window"}`. After a click in the pane, macOS `screencapture`
/// runs its own region pick (`-i`) or window pick (`-iW`), so the selection UI and the Screen
/// Recording permission are the system's. It answers `{name, mimeType, data}` (base64 of the PNG
/// as `screencapture` wrote it, at any size) or `{cancelled: true}` when the person presses Esc.
/// The page makes the model's preview itself (composer/imageWork.ts) and saves this original for
/// the agent as it does a pasted screenshot's (composer/intakeFiles.ts): attachments have no size
/// cap (Leo, 2026-10-26).
enum AgentPaneCapture {
    nonisolated static let tool = "/usr/sbin/screencapture"

    @MainActor static func reply(to mode: String?, in model: AgentPaneModel) async -> [String: Any] {
        guard let mode, mode == "screen" || mode == "window" else { return AgentPaneModel.unsupported("composer.capture") }
        // The screen goes to the agent: only a click in the pane starts a capture.
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-\(UUID().uuidString).png")
        guard await capture(window: mode == "window", to: file) else { return AgentPaneReply.success(["cancelled": true]) }
        let taken = Date()
        // A person waits for the attachment: the read runs at userBlocking's priority.
        let value = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { () -> [String: any Sendable] in
            defer { try? FileManager.default.removeItem(at: file) }
            return Self.answer((try? Data(contentsOf: file)) ?? Data(), taken: taken)
        }.value
        return AgentPaneReply.success(value)
    }

    /// The page's answer for the bytes `screencapture` wrote: the image named for when it was
    /// `taken` (as macOS names its own, so two in one prompt differ), its bytes as written, never
    /// scaled; `cancelled` for none (Esc).
    nonisolated static func answer(_ png: Data, taken: Date) -> [String: any Sendable] {
        guard !png.isEmpty else { return ["cancelled": true] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Screenshot \(formatter.string(from: taken)).png"
        return ["name": name, "mimeType": "image/png", "data": png.base64EncodedString()]
    }

    /// Runs the pick; false when `screencapture` could not start. Its caller is the main actor: the spawn
    /// runs on AsyncProcess's own queue, and the wait holds no thread.
    nonisolated static func capture(window: Bool, to file: URL) async -> Bool {
        // -x: no shutter sound; -o: no window shadow.
        let arguments = (window ? ["-i", "-W", "-o"] : ["-i"]) + ["-x", "-t", "png", file.path]
        return (try? await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: tool), arguments))) != nil
    }
}
