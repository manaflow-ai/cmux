#if DEBUG
import Foundation

/// Adapts the blocking debug socket handler without blocking the main actor.
struct FeedSidebarUITestPushClient: Sendable {
    let handleSocketLine: @Sendable (String) -> String

    func push(requestId: String) async -> [String: String] {
        // feed.push waits for the UI reply; it must run outside the main actor.
        await Task.detached(priority: .userInitiated) {
            var result = updates(response: handleSocketLine(request(requestId: requestId)))
            if result["pushResultStatus"] == "resolved" {
                result["shortcutResponse"] = handleSocketLine("simulate_shortcut ctrl+3")
            }
            return result
        }.value
    }

    private func request(requestId: String) -> String {
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
        return line
    }

    private func updates(response: String) -> [String: String] {
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

}
#endif
