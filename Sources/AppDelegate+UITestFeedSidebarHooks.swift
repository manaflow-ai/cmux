import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation

// MARK: - UITest hooks: feed sidebar (DEBUG)
extension AppDelegate {
#if DEBUG
    func setupFeedSidebarUITestIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard !didSetupFeedSidebarUITest else { return }
        guard let path = env["CMUX_UI_TEST_FEED_SIDEBAR_RESULT_PATH"], !path.isEmpty else { return }
        didSetupFeedSidebarUITest = true

        setupFeedSidebarUITestReveal(resultPath: path)
        writeFeedSidebarUITestData(["stage": "revealOnly"], at: path)
    }

    private func setupFeedSidebarUITestReveal(resultPath: String) {
        var observer: NSObjectProtocol?
        let attemptReveal: () -> Void = { [weak self] in
            guard let self else { return }
            let result = self.debugRevealRightSidebarInActiveMainWindow(
                mode: .dock,
                focusFirstItem: false,
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            )
            self.writeFeedSidebarUITestData([
                "reveal": result.revealed ? "1" : "0",
                "revealVisible": result.visible ? "1" : "0",
                "revealContextFound": result.contextFound ? "1" : "0",
                "revealStateFound": result.stateFound ? "1" : "0",
                "revealActiveMode": result.activeMode ?? "",
            ], at: resultPath)
            self.writeUITestDiagnosticsIfNeeded(
                stage: result.revealed ? "feedSidebarUITest.reveal.ok" : "feedSidebarUITest.reveal.pending"
            )
            if result.revealed {
                self.startFeedSidebarUITestPushIfNeeded(resultPath: resultPath)
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }

        observer = NotificationCenter.default.addObserver(
            forName: .mainWindowContextsDidChange,
            object: self,
            queue: .main
        ) { _ in
            attemptReveal()
        }
        if let observer {
            feedSidebarUITestObservers.append(observer)
        }
        DispatchQueue.main.async(execute: attemptReveal)
    }

    private func startFeedSidebarUITestPushIfNeeded(resultPath: String) {
        let env = ProcessInfo.processInfo.environment
        guard !didStartFeedSidebarUITestPush else { return }
        guard let requestId = env["CMUX_UI_TEST_FEED_SIDEBAR_REQUEST_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !requestId.isEmpty else {
            return
        }
        didStartFeedSidebarUITestPush = true

        writeFeedSidebarUITestData([
            "pushStarted": "1",
            "pushRequestId": requestId,
        ], at: resultPath)
        observeFeedSidebarUITestPending(requestId: requestId, resultPath: resultPath)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var updates = Self.feedSidebarUITestPushUpdates(response: Self.runFeedSidebarUITestPush(requestId: requestId))
            if updates["pushResultStatus"] == "resolved" { updates["shortcutResponse"] = TerminalController.shared.handleSocketLine("simulate_shortcut ctrl+3") }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.writeFeedSidebarUITestData(updates, at: resultPath)
                self.writeUITestDiagnosticsIfNeeded(stage: "feedSidebarUITest.push.finished")
            }
        }
    }

    private func observeFeedSidebarUITestPending(
        requestId: String,
        resultPath: String,
        remainingAttempts: Int = 75
    ) {
        let pending = FeedCoordinator.shared.snapshot(pendingOnly: false).contains { item in
            guard item.status.isPending else { return false }
            if case .permissionRequest(let itemRequestId, _, _, _) = item.payload {
                return itemRequestId == requestId
            }
            return false
        }
        if pending {
            writeFeedSidebarUITestData([
                "pushPendingObserved": "1",
            ], at: resultPath)
            return
        }
        guard remainingAttempts > 0 else {
            writeFeedSidebarUITestData([
                "pushPendingObserved": "0",
            ], at: resultPath)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.observeFeedSidebarUITestPending(
                requestId: requestId,
                resultPath: resultPath,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private static func runFeedSidebarUITestPush(requestId: String) -> String {
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
        return TerminalController.shared.handleSocketLine(line)
    }

    private static func feedSidebarUITestPushUpdates(response: String) -> [String: String] {
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

    private func writeFeedSidebarUITestData(_ updates: [String: String], at path: String) {
        var payload: [String: String] = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            return object
        }()
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
#endif

}
