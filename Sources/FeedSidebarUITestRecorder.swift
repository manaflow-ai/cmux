#if DEBUG
import AppKit
import CmuxTestSupport
import Foundation

/// Records the feed-sidebar reveal/push UI-test state for the
/// `CMUX_UI_TEST_FEED_SIDEBAR_*` XCUITest scenario.
///
/// This is the app-target conformer of ``UITestRecording`` for the
/// feed-sidebar scenario. It owns the live `AppDelegate` it drives the
/// right-sidebar reveal through and reads the feed coordinator/control-socket
/// state from, which is why it cannot live in `CmuxTestSupport` (a lower
/// package cannot reference `AppDelegate`/`FeedCoordinator`/
/// `TerminalController`). ``installIfNeeded()`` is gated by
/// `CMUX_UI_TEST_FEED_SIDEBAR_RESULT_PATH` and is a no-op in production; it
/// carries its own one-shot guard so the composition root can call it
/// unconditionally during launch.
///
/// On install the recorder reveals the active main window's right sidebar in
/// dock mode (retrying on `mainWindowContextsDidChange` until it succeeds),
/// then, when a request id is configured, drives a `feed.push` over the
/// control socket on a background queue and observes the resulting pending
/// permission request. The capture-file path, JSON shape, and key set are
/// byte-identical to the legacy `AppDelegate` implementation this was lifted
/// from: a `[String: String]` object merged and re-serialized with unsorted
/// keys.
@MainActor
final class FeedSidebarUITestRecorder: UITestRecording {
    private unowned let appDelegate: AppDelegate
    private let environment: [String: String]
    private var didSetup = false
    private var didStartPush = false
    private var observers: [NSObjectProtocol] = []

    /// Creates a recorder bound to `appDelegate`, reading scenario gates from
    /// `environment`.
    ///
    /// - Parameters:
    ///   - appDelegate: The live app delegate whose right sidebar the recorder
    ///     reveals.
    ///   - environment: The process environment; defaults to the real one.
    init(
        appDelegate: AppDelegate,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.appDelegate = appDelegate
        self.environment = environment
    }

    func installIfNeeded() {
        guard !didSetup else { return }
        guard let path = environment["CMUX_UI_TEST_FEED_SIDEBAR_RESULT_PATH"], !path.isEmpty else { return }
        didSetup = true

        setupReveal(resultPath: path)
        writeData(["stage": "revealOnly"], at: path)
    }

    private func setupReveal(resultPath: String) {
        var observer: NSObjectProtocol?
        let attemptReveal: () -> Void = { [weak self] in
            guard let self else { return }
            let result = self.appDelegate.debugRevealRightSidebarInActiveMainWindow(
                mode: .dock,
                focusFirstItem: false,
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            )
            self.writeData([
                "reveal": result.revealed ? "1" : "0",
                "revealVisible": result.visible ? "1" : "0",
                "revealContextFound": result.contextFound ? "1" : "0",
                "revealStateFound": result.stateFound ? "1" : "0",
                "revealActiveMode": result.activeMode ?? "",
            ], at: resultPath)
            self.appDelegate.writeUITestDiagnosticsIfNeeded(
                stage: result.revealed ? "feedSidebarUITest.reveal.ok" : "feedSidebarUITest.reveal.pending"
            )
            if result.revealed {
                self.startPushIfNeeded(resultPath: resultPath)
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }

        observer = NotificationCenter.default.addObserver(
            forName: .mainWindowContextsDidChange,
            object: appDelegate,
            queue: .main
        ) { _ in
            attemptReveal()
        }
        if let observer {
            observers.append(observer)
        }
        DispatchQueue.main.async { attemptReveal() }
    }

    private func startPushIfNeeded(resultPath: String) {
        guard !didStartPush else { return }
        guard let requestId = environment["CMUX_UI_TEST_FEED_SIDEBAR_REQUEST_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !requestId.isEmpty else {
            return
        }
        didStartPush = true

        writeData([
            "pushStarted": "1",
            "pushRequestId": requestId,
        ], at: resultPath)
        observePending(requestId: requestId, resultPath: resultPath)

        // `TerminalController` is `@MainActor`, but `handleSocketLine` is
        // `nonisolated` and the original ran it off the main thread (it blocks on
        // the feed.push wait). Capture the controller on the main actor here, then
        // call its nonisolated socket method on the background queue, preserving
        // the original off-main blocking behavior without an off-main `.shared`
        // read.
        let controller = TerminalController.shared
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var updates = Self.pushUpdates(response: Self.runPush(requestId: requestId, controller: controller))
            if updates["pushResultStatus"] == "resolved" {
                updates["shortcutResponse"] = controller.handleSocketLine("simulate_shortcut ctrl+3")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.writeData(updates, at: resultPath)
                self.appDelegate.writeUITestDiagnosticsIfNeeded(stage: "feedSidebarUITest.push.finished")
            }
        }
    }

    private func observePending(
        requestId: String,
        resultPath: String,
        remainingAttempts: Int = 75
    ) {
        let pending = FeedCoordinator.shared.socketRouter.snapshot(pendingOnly: false).contains { item in
            guard item.status.isPending else { return false }
            if case .permissionRequest(let itemRequestId, _, _, _) = item.payload {
                return itemRequestId == requestId
            }
            return false
        }
        if pending {
            writeData(["pushPendingObserved": "1"], at: resultPath)
            return
        }
        guard remainingAttempts > 0 else {
            writeData(["pushPendingObserved": "0"], at: resultPath)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.observePending(
                requestId: requestId,
                resultPath: resultPath,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private nonisolated static func runPush(requestId: String, controller: TerminalController) -> String {
        let params: [String: Any] = [
            "event": [
                "session_id": "uitest-\(requestId)",
                "hook_event_name": "PermissionRequest",
                "_source": "claude",
                "tool_name": "Write",
                "tool_input": ["file_path": "/tmp/feeduitest"],
                "_opencode_request_id": requestId,
            ],
            "wait_timeout_seconds": 120,
        ]
        let frame: [String: Any] = [
            "id": UUID().uuidString,
            "method": "feed.push",
            "params": params,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let line = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"message\":\"failed to encode feed.push frame\"}}"
        }
        return controller.handleSocketLine(line)
    }

    private nonisolated static func pushUpdates(response: String) -> [String: String] {
        var updates: [String: String] = ["pushResponse": response]
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            updates["pushError"] = "invalid response: \(response)"
            return updates
        }
        guard object["ok"] as? Bool == true else {
            let error = object["error"] as? [String: Any]
            updates["pushError"] = (error?["message"] as? String) ?? "feed.push returned ok=false"
            return updates
        }
        guard let result = object["result"] as? [String: Any],
              let status = result["status"] as? String else {
            updates["pushError"] = "feed.push response missing result.status"
            return updates
        }
        updates["pushResultStatus"] = status
        if let decision = result["decision"] as? [String: Any],
           let mode = decision["mode"] as? String {
            updates["pushResultMode"] = mode
        }
        return updates
    }

    /// Merges `updates` into the feed-sidebar capture file at `path`, writing
    /// byte-faithfully with unsorted keys.
    ///
    /// Forwards to ``UITestKeyValueCaptureFile/merge(_:)``, the single tested
    /// owner of the load / merge / unsorted-write byte format, instead of the
    /// previously inlined load-merge-serialize copy.
    private func writeData(_ updates: [String: String], at path: String) {
        UITestKeyValueCaptureFile(path: path).merge(updates)
    }
}
#endif
