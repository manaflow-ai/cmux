import Foundation

/// The composer's + > Attach Screenshot… and Attach Window… (cx-ncc.71, the Codex app's Attach):
/// `composer.capture {mode: "screen" | "window"}`. After a click in the pane, macOS `screencapture`
/// runs its own region pick (`-i`) or window pick (`-iW`), so the selection UI and the Screen
/// Recording permission are the system's. It answers `{name, mimeType, data}` (a base64 PNG) for
/// the page to attach as an image, or `{cancelled: true}` when the person presses Esc.
enum AgentPaneCapture {
    static let tool = "/usr/sbin/screencapture"

    @MainActor static func reply(to mode: String?, in model: AgentPaneModel) async -> [String: Any] {
        guard let mode, mode == "screen" || mode == "window" else { return AgentPaneModel.unsupported("composer.capture") }
        // The screen goes to the agent: only a click in the pane starts a capture.
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        guard let png = await capture(window: mode == "window") else { return AgentPaneReply.success(["cancelled": true]) }
        return AgentPaneReply.success(["name": "Screenshot.png", "mimeType": "image/png", "data": png.base64EncodedString()])
    }

    /// The PNG `screencapture` wrote, or nil when the pick was cancelled or the tool failed.
    nonisolated static func capture(window: Bool) async -> Data? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        // -x: no shutter sound; -o: no window shadow.
        process.arguments = (window ? ["-i", "-W", "-o"] : ["-i"]) + ["-x", "-t", "png", file.path]
        let ran: Bool = await withCheckedContinuation { done in
            process.terminationHandler = { _ in done.resume(returning: true) }
            do { try process.run() } catch { done.resume(returning: false) }
        }
        guard ran else { return nil }
        return try? Data(contentsOf: file)
    }
}
