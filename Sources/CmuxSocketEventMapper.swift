import Foundation

enum CmuxSocketEventMapper {
    static func publish(command: String, response: String) {
        autoreleasepool {
            if publishV2(command: command, response: response) {
                return
            }
            publishV1(command: command, response: response)
        }
    }

    private static func publishV2(command: String, response: String) -> Bool {
        guard command.hasPrefix("{"),
              let requestData = command.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let method = request["method"] as? String else {
            return false
        }
        guard method != "events.stream" else { return true }
        guard let mapping = domainEventMapping(forV2Method: method) else {
            return true
        }

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
        publishResult(
            name: mapping.resolvedName(using: result),
            category: mapping.category,
            method: method,
            params: mappedParams(params, using: mapping.params),
            result: result
        )
        return true
    }

    private struct DomainEventMapping {
        let name: String
        let remoteName: String?
        let category: String
        let params: ParameterMapping

        init(
            name: String,
            remoteName: String? = nil,
            category: String,
            params: ParameterMapping
        ) {
            self.name = name
            self.remoteName = remoteName
            self.category = category
            self.params = params
        }

        func resolvedName(using result: [String: Any]) -> String {
            if result["remote"] as? Bool == true, let remoteName {
                return remoteName
            }
            return name
        }
    }

    private enum ParameterMapping {
        case unchanged
        case redactedInput
        case redactedNotification
    }

    private static func domainEventMapping(forV2Method method: String) -> DomainEventMapping? {
        switch method {
        case "workspace.rename":
            return DomainEventMapping(name: "workspace.renamed", category: "workspace", params: .unchanged)
        case "workspace.move_to_window":
            return DomainEventMapping(name: "workspace.moved", category: "workspace", params: .unchanged)
        case "workspace.action":
            return DomainEventMapping(name: "workspace.action", category: "workspace", params: .unchanged)
        case "surface.split_off", "surface.drag_to_split":
            return DomainEventMapping(name: "pane.created", category: "pane", params: .unchanged)
        case "surface.move":
            return DomainEventMapping(name: "surface.moved", category: "surface", params: .unchanged)
        case "surface.reorder":
            return DomainEventMapping(name: "surface.reordered", category: "surface", params: .unchanged)
        case "surface.action", "tab.action":
            return DomainEventMapping(name: "surface.action", category: "surface", params: .unchanged)
        case "surface.send_text":
            return DomainEventMapping(name: "surface.input_sent", category: "surface", params: .redactedInput)
        case "surface.send_key":
            return DomainEventMapping(name: "surface.key_sent", category: "surface", params: .unchanged)
        case "pane.resize":
            return DomainEventMapping(
                name: "pane.resized",
                remoteName: "pane.resize_requested",
                category: "pane",
                params: .unchanged
            )
        case "pane.swap":
            return DomainEventMapping(name: "pane.swapped", category: "pane", params: .unchanged)
        case "pane.break":
            return DomainEventMapping(name: "pane.broken", category: "pane", params: .unchanged)
        case "pane.join":
            return DomainEventMapping(name: "pane.joined", category: "pane", params: .unchanged)
        case "notification.create", "notification.create_for_caller", "notification.create_for_surface", "notification.create_for_target":
            return DomainEventMapping(name: "notification.requested", category: "notification", params: .redactedNotification)
        case "notification.clear":
            return DomainEventMapping(name: "notification.clear_requested", category: "notification", params: .unchanged)
        case "notification.dismiss":
            return DomainEventMapping(name: "notification.dismiss_requested", category: "notification", params: .unchanged)
        case "notification.mark_read":
            return DomainEventMapping(name: "notification.mark_read_requested", category: "notification", params: .unchanged)
        case "notification.open":
            return DomainEventMapping(name: "notification.open_requested", category: "notification", params: .unchanged)
        case "notification.jump_to_unread":
            return DomainEventMapping(name: "notification.jump_to_unread_requested", category: "notification", params: .unchanged)
        case "feed.permission.reply", "feed.question.reply", "feed.exit_plan.reply":
            return DomainEventMapping(name: "feed.item.resolved", category: "feed", params: .unchanged)
        case "app.focus_override.set":
            return DomainEventMapping(name: "app.focus_override.changed", category: "app", params: .unchanged)
        case "app.simulate_active":
            return DomainEventMapping(name: "app.simulated_active", category: "app", params: .unchanged)
        case "browser.navigate", "browser.back", "browser.forward", "browser.reload":
            return DomainEventMapping(name: "browser.navigation", category: "browser", params: .unchanged)
        case "browser.click", "browser.dblclick", "browser.hover", "browser.focus", "browser.press", "browser.keydown", "browser.keyup", "browser.check", "browser.uncheck", "browser.select", "browser.scroll", "browser.scroll_into_view":
            return DomainEventMapping(name: "browser.interaction", category: "browser", params: .unchanged)
        case "browser.type", "browser.fill":
            return DomainEventMapping(name: "browser.input", category: "browser", params: .redactedInput)
        default:
            return nil
        }
    }

    private static func mappedParams(_ params: [String: Any], using mapping: ParameterMapping) -> [String: Any] {
        switch mapping {
        case .unchanged:
            return params
        case .redactedInput:
            return redactedInputParams(params)
        case .redactedNotification:
            return redactedNotificationParams(params)
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
