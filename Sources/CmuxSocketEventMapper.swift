import CmuxControlSocket
import Foundation

enum CmuxSocketEventMapper {
    /// `caller` is a provider rather than a value so the pid → process name and
    /// pid → surface lookups only run when a command actually maps to an event.
    /// Callers memoize it per connection; the peer pid is fixed for a
    /// connection's lifetime, so the identity is resolved at most once there.
    static func publish(
        command: String,
        response: String,
        caller: () -> CmuxSocketCallerIdentity = { .unknown }
    ) {
        autoreleasepool {
            if publishV2(command: command, response: response, caller: caller) {
                return
            }
            publishV1(command: command, response: response, caller: caller)
        }
    }

    /// v1 command names that publish an event. Kept as data so the eager
    /// caller-identity resolution in `TerminalController` can ask "will this
    /// command publish?" without running the command first.
    /// `v1PublishingCommandsMatchPublishV1` guards this against drift.
    static let v1PublishingCommands: Set<String> = [
        "send", "send_surface",
        "send_key", "send_key_surface",
        "notify_surface", "notify", "notify_target", "notify_target_async",
        "clear_notifications",
        "set_status", "report_meta", "report_meta_block",
        "clear_status", "clear_meta", "clear_meta_block",
        "set_progress", "clear_progress",
        "log", "clear_log", "reset_sidebar",
        "reload_config", "set_app_focus", "simulate_app_active",
    ]

    /// Whether this command can produce an event, judged from the request alone.
    ///
    /// The caller identity must be resolved while the peer is still alive, and a
    /// short-lived `cmux send` often exits between the response and the publish.
    /// Resolving eagerly for every command would put a main hop on commands that
    /// publish nothing, so the socket loop uses this to resolve only when it
    /// matters. A false positive (the command fails, so no event) costs one
    /// wasted lookup; a false negative would only lose optional attribution.
    static func mapsToEvent(command: String) -> Bool {
        if command.hasPrefix("{") {
            guard let data = command.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = request["method"] as? String else {
                return false
            }
            return method != "events.stream" && domainEventMapping(forV2Method: method) != nil
        }
        guard let rawName = command.split(separator: " ", maxSplits: 1).first else { return false }
        return v1PublishingCommands.contains(rawName.lowercased())
    }

    private static func publishV2(
        command: String,
        response: String,
        caller: () -> CmuxSocketCallerIdentity
    ) -> Bool {
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
            result: result,
            caller: caller()
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

    /// Redaction policy for injected input (https://github.com/manaflow-ai/cmux/issues/9611).
    ///
    /// One rule decides both input methods: free-form caller text is redacted to
    /// a length, bounded control vocabulary is recorded verbatim. `surface.send_text`
    /// carries arbitrary user content and is `.redactedInput`. `surface.send_key`
    /// carries a `key` drawn from a fixed named-key table that the server
    /// validates before the command succeeds (an unknown key returns an error, so
    /// no event is published), which cannot contain a secret and is the whole
    /// diagnostic value of the record, so it is `.boundedInput`.
    ///
    /// `.boundedInput` differs from `.unchanged` only in that it states the
    /// decision in the record: it emits `redacted_fields: []`, so a reader can
    /// tell "nothing here needed redacting" apart from a method that never
    /// considered redaction at all.
    private enum ParameterMapping {
        case unchanged
        case boundedInput
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
            return DomainEventMapping(name: "surface.key_sent", category: "surface", params: .boundedInput)
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
        case .boundedInput:
            var out = params
            out["redacted_fields"] = (out["redacted_fields"] as? [String]) ?? []
            return out
        case .redactedInput:
            return redactedInputParams(params)
        case .redactedNotification:
            return redactedNotificationParams(params)
        }
    }

    private static func publishV1(
        command: String,
        response: String,
        caller: () -> CmuxSocketCallerIdentity
    ) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let rawName = parts.first else { return }
        let name = rawName.lowercased()
        guard response == "OK" || response.hasPrefix("OK ") || response.hasPrefix("OK\n") || response.hasPrefix("OK:") else { return }
        let args = parts.count > 1 ? parts[1] : ""
        let payload: [String: Any] = ["command": name, "args": redactedV1Args(name: name, args: args)]

        // v1 events carry the same attribution as v2. At most one case below
        // publishes, so `caller()` runs at most once per command.
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
            // `redactedV1Args` already replaced the args with `<redacted>`;
            // name the redacted field so v1 and v2 readers see the same marker.
            var textPayload = payload
            textPayload["redacted_fields"] = ["args"]
            CmuxEventBus.shared.publish(caller: caller(), name: "surface.input_sent", category: "surface", source: "socket.v1", payload: textPayload)
        case "send_key", "send_key_surface":
            // Same policy as v2 `surface.send_key`: the key is bounded control
            // vocabulary and is recorded, and the empty marker says redaction
            // was considered. `docs/events.md` documents the field as present
            // on every `surface.key_sent`, v1 included.
            var keyPayload = payload
            keyPayload["redacted_fields"] = [String]()
            CmuxEventBus.shared.publish(caller: caller(), name: "surface.key_sent", category: "surface", source: "socket.v1", payload: keyPayload)
        case "notify_surface":
            var payloadWithSurface = payload
            let surfaceId = firstUUID(in: args)
            payloadWithSurface["surface_id"] = surfaceId ?? NSNull()
            CmuxEventBus.shared.publish(
                caller: caller(),
                name: "notification.requested",
                category: "notification",
                source: "socket.v1",
                surfaceId: surfaceId,
                payload: payloadWithSurface
            )
        case "notify", "notify_target", "notify_target_async":
            CmuxEventBus.shared.publish(caller: caller(), name: "notification.requested", category: "notification", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "clear_notifications":
            CmuxEventBus.shared.publish(caller: caller(), name: "notification.clear_requested", category: "notification", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "set_status", "report_meta", "report_meta_block":
            CmuxEventBus.shared.publish(caller: caller(), name: "sidebar.metadata.updated", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "clear_status", "clear_meta", "clear_meta_block":
            CmuxEventBus.shared.publish(caller: caller(), name: "sidebar.metadata.cleared", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "set_progress":
            CmuxEventBus.shared.publish(caller: caller(), name: "sidebar.progress.updated", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "clear_progress":
            CmuxEventBus.shared.publish(caller: caller(), name: "sidebar.progress.cleared", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "log":
            CmuxEventBus.shared.publish(caller: caller(), name: "sidebar.log.appended", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "clear_log":
            CmuxEventBus.shared.publish(caller: caller(), name: "sidebar.log.cleared", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "reset_sidebar":
            CmuxEventBus.shared.publish(caller: caller(), name: "sidebar.reset", category: "sidebar", source: "socket.v1", workspaceId: firstUUID(in: args), payload: payload)
        case "reload_config":
            CmuxEventBus.shared.publish(caller: caller(), name: "config.reloaded", category: "config", source: "socket.v1", payload: payload)
        case "set_app_focus":
            CmuxEventBus.shared.publish(caller: caller(), name: "app.focus_override.changed", category: "app", source: "socket.v1", payload: payload)
        case "simulate_app_active":
            CmuxEventBus.shared.publish(caller: caller(), name: "app.simulated_active", category: "app", source: "socket.v1", payload: payload)
        default:
            break
        }
    }

    private static func publishResult(
        name: String,
        category: String,
        method: String,
        params: [String: Any],
        result: [String: Any],
        caller: CmuxSocketCallerIdentity
    ) {
        let workspaceId = stringValue(result["workspace_id"] ?? params["workspace_id"])
        let surfaceId = stringValue(result["surface_id"] ?? params["surface_id"])
        let paneId = stringValue(result["pane_id"] ?? params["pane_id"])
        let windowId = stringValue(result["window_id"] ?? params["window_id"])
        CmuxEventBus.shared.publish(
            caller: caller,
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
