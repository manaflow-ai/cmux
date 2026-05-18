import Foundation

enum CmuxSocketEventMapper {
    static func publish(command: String, response: String) {
        if publishV2(command: command, response: response) {
            return
        }
        publishV1(command: command, response: response)
    }

    private static func publishV2(command: String, response: String) -> Bool {
        guard command.hasPrefix("{"),
              let requestData = command.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let method = request["method"] as? String else {
            return false
        }
        guard method != "events.stream" else { return true }

        let responseObject: [String: Any]
        if let responseData = response.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            responseObject = parsed
        } else {
            responseObject = ["ok": false, "error": ["message": response]]
        }

        guard (responseObject["ok"] as? Bool) == true else {
            return true
        }

        let params = request["params"] as? [String: Any] ?? [:]
        let result = responseObject["result"] as? [String: Any] ?? [:]
        publishDomainEventForV2(method: method, params: params, result: result)
        return true
    }

    private static func publishDomainEventForV2(method: String, params: [String: Any], result: [String: Any]) {
        switch method {
        case "window.create", "window.focus", "window.close":
            break
        case "workspace.create", "workspace.select", "workspace.next", "workspace.previous", "workspace.last", "workspace.close":
            break
        case "workspace.rename":
            publishResult(name: "workspace.renamed", category: "workspace", method: method, params: params, result: result)
        case "workspace.reorder":
            publishResult(name: "workspace.reordered", category: "workspace", method: method, params: params, result: result)
        case "workspace.move_to_window":
            publishResult(name: "workspace.moved", category: "workspace", method: method, params: params, result: result)
        case "workspace.action":
            publishResult(name: "workspace.action", category: "workspace", method: method, params: params, result: result)
        case "surface.create", "surface.split", "browser.open_split", "markdown.open", "file.open":
            break
        case "surface.split_off", "surface.drag_to_split":
            publishResult(name: "pane.created", category: "pane", method: method, params: params, result: result)
        case "surface.focus":
            break
        case "surface.close":
            break
        case "surface.move":
            publishResult(name: "surface.moved", category: "surface", method: method, params: params, result: result)
        case "surface.reorder":
            publishResult(name: "surface.reordered", category: "surface", method: method, params: params, result: result)
        case "surface.action", "tab.action":
            publishResult(name: "surface.action", category: "surface", method: method, params: params, result: result)
        case "surface.send_text":
            publishResult(name: "surface.input_sent", category: "surface", method: method, params: redactedInputParams(params), result: result)
        case "surface.send_key":
            publishResult(name: "surface.key_sent", category: "surface", method: method, params: params, result: result)
        case "pane.create":
            break
        case "pane.focus", "pane.last":
            break
        case "pane.resize":
            publishResult(name: "pane.resized", category: "pane", method: method, params: params, result: result)
        case "pane.swap":
            publishResult(name: "pane.swapped", category: "pane", method: method, params: params, result: result)
        case "pane.break":
            publishResult(name: "pane.broken", category: "pane", method: method, params: params, result: result)
        case "pane.join":
            publishResult(name: "pane.joined", category: "pane", method: method, params: params, result: result)
        case "notification.create", "notification.create_for_caller", "notification.create_for_surface", "notification.create_for_target":
            publishResult(name: "notification.requested", category: "notification", method: method, params: redactedNotificationParams(params), result: result)
        case "notification.clear":
            publishResult(name: "notification.clear_requested", category: "notification", method: method, params: params, result: result)
        case "notification.dismiss":
            publishResult(name: "notification.dismiss_requested", category: "notification", method: method, params: params, result: result)
        case "notification.mark_read":
            publishResult(name: "notification.mark_read_requested", category: "notification", method: method, params: params, result: result)
        case "notification.open":
            publishResult(name: "notification.open_requested", category: "notification", method: method, params: params, result: result)
        case "notification.jump_to_unread":
            publishResult(name: "notification.jump_to_unread_requested", category: "notification", method: method, params: params, result: result)
        case "feed.permission.reply", "feed.question.reply", "feed.exit_plan.reply":
            publishResult(name: "feed.item.resolved", category: "feed", method: method, params: params, result: result)
        case "app.focus_override.set":
            publishResult(name: "app.focus_override.changed", category: "app", method: method, params: params, result: result)
        case "app.simulate_active":
            publishResult(name: "app.simulated_active", category: "app", method: method, params: params, result: result)
        case "browser.navigate", "browser.back", "browser.forward", "browser.reload":
            publishResult(name: "browser.navigation", category: "browser", method: method, params: params, result: result)
        case "browser.click", "browser.dblclick", "browser.hover", "browser.focus", "browser.press", "browser.keydown", "browser.keyup", "browser.check", "browser.uncheck", "browser.select", "browser.scroll", "browser.scroll_into_view":
            publishResult(name: "browser.interaction", category: "browser", method: method, params: params, result: result)
        case "browser.type", "browser.fill":
            publishResult(name: "browser.input", category: "browser", method: method, params: redactedInputParams(params), result: result)
        default:
            break
        }
    }

    private static func publishV1(command: String, response: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let rawName = parts.first else { return }
        let name = rawName.lowercased()
        guard response == "OK" || response.hasPrefix("OK ") || response.hasPrefix("OK\n") || response.hasPrefix("OK:") else { return }
        let args = parts.count > 1 ? parts[1] : ""
        let payload: [String: Any] = ["command": name, "args": redactedV1Args(name: name, args: args)]

        switch name {
        case "new_window", "focus_window", "close_window":
            break
        case "new_workspace", "select_workspace", "close_workspace", "new_split", "new_pane", "new_surface", "open_browser":
            break
        case "focus_surface", "focus_surface_by_panel", "focus_pane":
            break
        case "close_surface":
            break
        case "send", "send_surface":
            CmuxEventBus.shared.publish(name: "surface.input_sent", category: "surface", source: "socket.v1", payload: payload)
        case "send_key", "send_key_surface":
            CmuxEventBus.shared.publish(name: "surface.key_sent", category: "surface", source: "socket.v1", payload: payload)
        case "notify_surface":
            var payloadWithSurface = payload
            let surfaceId = firstUUID(in: args)
            payloadWithSurface["surface_id"] = surfaceId ?? NSNull()
            CmuxEventBus.shared.publish(
                name: "notification.requested",
                category: "notification",
                source: "socket.v1",
                surfaceId: surfaceId,
                payload: payloadWithSurface
            )
        case "notify", "notify_target", "notify_target_async":
            CmuxEventBus.shared.publish(name: "notification.requested", category: "notification", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "clear_notifications":
            CmuxEventBus.shared.publish(name: "notification.clear_requested", category: "notification", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "set_status", "report_meta", "report_meta_block":
            CmuxEventBus.shared.publish(name: "sidebar.metadata.updated", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "clear_status", "clear_meta", "clear_meta_block":
            CmuxEventBus.shared.publish(name: "sidebar.metadata.cleared", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "set_progress":
            CmuxEventBus.shared.publish(name: "sidebar.progress.updated", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "clear_progress":
            CmuxEventBus.shared.publish(name: "sidebar.progress.cleared", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "log":
            CmuxEventBus.shared.publish(name: "sidebar.log.appended", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "clear_log":
            CmuxEventBus.shared.publish(name: "sidebar.log.cleared", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "reset_sidebar":
            CmuxEventBus.shared.publish(name: "sidebar.reset", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "reload_config":
            CmuxEventBus.shared.publish(name: "config.reloaded", category: "config", source: "socket.v1", payload: payload)
        case "set_app_focus":
            CmuxEventBus.shared.publish(name: "app.focus_override.changed", category: "app", source: "socket.v1", payload: payload)
        case "simulate_app_active":
            CmuxEventBus.shared.publish(name: "app.simulated_active", category: "app", source: "socket.v1", payload: payload)
        default:
            break
        }
    }

    private static func publishResult(name: String, category: String, method: String, params: [String: Any], result: [String: Any]) {
        let workspaceId = stringValue(result["workspace_id"] ?? params["workspace_id"])
        let surfaceId = stringValue(result["surface_id"] ?? params["surface_id"])
        let paneId = stringValue(result["pane_id"] ?? params["pane_id"])
        let windowId = stringValue(result["window_id"] ?? params["window_id"])
        CmuxEventBus.shared.publish(
            name: name,
            category: category,
            source: "socket.v2",
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            paneId: paneId,
            windowId: windowId,
            payload: [
                "method": method,
                "params": params,
                "result": result
            ]
        )
    }

    private static func redactedInputParams(_ params: [String: Any]) -> [String: Any] {
        var out = params
        if let text = out["text"] as? String {
            out["text"] = NSNull()
            out["text_length"] = text.count
            out["redacted_fields"] = ["text"]
        }
        if let value = out["value"] as? String {
            out["value"] = NSNull()
            out["value_length"] = value.count
            out["redacted_fields"] = ((out["redacted_fields"] as? [String]) ?? []) + ["value"]
        }
        return out
    }

    static func redactedNotificationParams(_ params: [String: Any]) -> [String: Any] {
        var out = params
        var redactedFields = (out["redacted_fields"] as? [String]) ?? []
        for key in ["title", "subtitle", "body"] {
            if let text = out[key] as? String {
                out[key] = NSNull()
                out["\(key)_length"] = text.count
                if !redactedFields.contains(key) {
                    redactedFields.append(key)
                }
            }
        }
        if !redactedFields.isEmpty {
            out["redacted_fields"] = redactedFields
        }
        return out
    }

    private static func redactedV1Args(name: String, args: String) -> String {
        switch name {
        case "send", "send_surface", "notify", "notify_surface", "notify_target", "notify_target_async":
            return "<redacted>"
        default:
            return args
        }
    }

    private static func firstUUID(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if UUID(uuidString: cleaned) != nil {
                return cleaned
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let uuid = value as? UUID { return uuid.uuidString }
        return nil
    }
}
