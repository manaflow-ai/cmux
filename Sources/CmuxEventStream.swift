import Darwin
import Foundation

extension TerminalController {
    nonisolated func isEventsStreamRequest(_ line: String) -> Bool {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            return false
        }
        return method == "events.stream"
    }

    nonisolated func handleEventsStreamRequest(_ line: String, socket: Int32) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            _ = writeEventsStreamLine([
                "type": "error",
                "ok": false,
                "error": ["code": "invalid_request", "message": "events.stream requires a JSON object"]
            ], socket: socket)
            return
        }

        let params = object["params"] as? [String: Any] ?? [:]
        let afterSequence = CmuxEventBus.int64(params["after_seq"] ?? params["after"])
        let names = Self.stringSet(params["names"] ?? params["name"])
        let categories = Self.stringSet(params["categories"] ?? params["category"])
        let includeHeartbeats = Self.boolParam(params["include_heartbeats"] ?? params["include_heartbeat"]) ?? true
        let scope: CmuxEventScope
        do {
            scope = try resolveEventsScope(params: params)
        } catch let error as EventsScopeError {
            _ = writeEventsStreamLine([
                "type": "error",
                "ok": false,
                "error": ["code": "invalid_params", "message": error.message]
            ], socket: socket)
            return
        } catch {
            _ = writeEventsStreamLine([
                "type": "error",
                "ok": false,
                "error": ["code": "invalid_params", "message": "Invalid event scope"]
            ], socket: socket)
            return
        }

        let snapshot = CmuxEventBus.shared.subscribe(
            afterSequence: afterSequence,
            names: names,
            categories: categories,
            scope: scope
        )
        defer { CmuxEventBus.shared.unsubscribe(snapshot.subscription) }

        guard writeEventsStreamLine(snapshot.ack, socket: socket) else { return }
        for event in snapshot.replay {
            guard writeEventsStreamLine(event, socket: socket) else { return }
        }

        while true {
            if let event = snapshot.subscription.next(timeout: CmuxEventBus.defaultHeartbeatIntervalSeconds) {
                guard writeEventsStreamLine(event, socket: socket) else { return }
            } else if snapshot.subscription.isClosed {
                if let reason = snapshot.subscription.closeReason {
                    _ = writeEventsStreamLine([
                        "type": "error",
                        "ok": false,
                        "error": [
                            "code": "slow_consumer",
                            "message": reason,
                            "latest_seq": NSNumber(value: CmuxEventBus.shared.latestSequence)
                        ]
                    ], socket: socket)
                }
                return
            } else if includeHeartbeats {
                let heartbeat = CmuxEventBus.shared.heartbeat(subscription: snapshot.subscription)
                guard writeEventsStreamLine(heartbeat, socket: socket) else { return }
            } else if Self.socketPeerClosed(socket) {
                return
            }
        }
    }

    nonisolated func publishSocketEvents(command: String, response: String) {
        CmuxSocketEventMapper.publish(command: command, response: response)
    }

    private nonisolated func writeEventsStreamLine(_ object: [String: Any], socket: Int32) -> Bool {
        guard let line = CmuxEventBus.encodeLine(object) else { return false }
        return Self.writeAllToSocket(Data((line + "\n").utf8), to: socket)
    }

    private struct EventsScopeError: Error {
        let message: String
    }

    private nonisolated func resolveEventsScope(params: [String: Any]) throws -> CmuxEventScope {
        let inferredKind = try inferEventsScopeKind(params: params)
        switch inferredKind {
        case .global:
            return .global
        case .window:
            guard let windowId = try resolveEventsWindowId(params: params) else {
                throw EventsScopeError(message: "Event scope window requires a resolvable window_id or caller/focused window")
            }
            return CmuxEventScope(
                kind: .window,
                windowId: windowId.uuidString,
                windowWorkspaceIds: eventWorkspaceIds(windowId: windowId),
                currentWindowWorkspaceIdsProvider: { [weak self] in
                    self?.eventWorkspaceIds(windowId: windowId) ?? []
                }
            )
        case .workspace:
            guard let workspaceId = try resolveEventsWorkspaceId(params: params) else {
                throw EventsScopeError(message: "Event scope workspace requires a resolvable workspace_id or caller/focused workspace")
            }
            return CmuxEventScope(kind: .workspace, workspaceId: workspaceId.uuidString)
        case .surface:
            guard let surfaceId = try resolveEventsSurfaceId(params: params) else {
                throw EventsScopeError(message: "Event scope surface requires a resolvable surface_id or caller/focused surface")
            }
            return CmuxEventScope(kind: .surface, surfaceId: surfaceId.uuidString)
        case .pane:
            guard let paneId = try resolveEventsPaneId(params: params) else {
                throw EventsScopeError(message: "Event scope pane requires a resolvable pane_id or focused pane")
            }
            return CmuxEventScope(kind: .pane, paneId: paneId.uuidString)
        }
    }

    private nonisolated func inferEventsScopeKind(params: [String: Any]) throws -> CmuxEventScope.Kind {
        if let raw = Self.stringValue(params["scope"] ?? params["scope_kind"]) {
            switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "global", "all":
                return .global
            case "window", "current-window":
                return .window
            case "workspace", "tab":
                return .workspace
            case "surface", "panel":
                return .surface
            case "pane":
                return .pane
            default:
                throw EventsScopeError(message: "Unknown event scope: \(raw)")
            }
        }
        if Self.hasNonNullParam(params, "pane_id") { return .pane }
        if Self.hasNonNullParam(params, "surface_id") || Self.hasNonNullParam(params, "tab_id") { return .surface }
        if Self.hasNonNullParam(params, "workspace_id") { return .workspace }
        if Self.hasNonNullParam(params, "window_id") { return .window }
        return .global
    }

    private nonisolated func resolveEventsWindowId(params: [String: Any]) throws -> UUID? {
        if Self.hasNonNullParam(params, "window_id") {
            guard let windowId = eventUUID(params: params, key: "window_id") else {
                throw EventsScopeError(message: "Missing or invalid window_id")
            }
            return windowId
        }

        if Self.hasNonNullParam(params, "workspace_id") {
            guard let workspaceId = eventUUID(params: params, key: "workspace_id") else {
                throw EventsScopeError(message: "Missing or invalid workspace_id")
            }
            return eventWindowId(workspaceId: workspaceId)
        }

        if Self.hasNonNullParam(params, "surface_id") || Self.hasNonNullParam(params, "tab_id") {
            guard let surfaceId = try resolveEventsSurfaceId(params: params) else { return nil }
            return v2MainSync { AppDelegate.shared?.locateSurface(surfaceId: surfaceId)?.windowId }
        }

        if Self.hasNonNullParam(params, "pane_id") {
            let context = eventFocusedContext(params: params)
            guard let windowId = context.windowId else {
                throw EventsScopeError(message: "Event scope window context was not found")
            }
            return windowId
        }

        if let callerWorkspaceId = eventCallerUUID(params: params, key: "workspace_id") {
            return eventWindowId(workspaceId: callerWorkspaceId)
        }
        if let callerSurfaceId = eventCallerUUID(params: params, key: "surface_id") ??
            eventCallerUUID(params: params, key: "tab_id") {
            return v2MainSync { AppDelegate.shared?.locateSurface(surfaceId: callerSurfaceId)?.windowId }
        }

        return eventFocusedContext(params: params).windowId
    }

    private nonisolated func resolveEventsWorkspaceId(params: [String: Any]) throws -> UUID? {
        if Self.hasNonNullParam(params, "workspace_id") {
            guard let workspaceId = eventUUID(params: params, key: "workspace_id") else {
                throw EventsScopeError(message: "Missing or invalid workspace_id")
            }
            return workspaceId
        }
        if Self.hasNonNullParam(params, "surface_id") || Self.hasNonNullParam(params, "tab_id") {
            guard let surfaceId = try resolveEventsSurfaceId(params: params) else { return nil }
            return eventWorkspaceId(surfaceId: surfaceId)
        }
        let hasExplicitWorkspaceContext = Self.hasNonNullParam(params, "window_id") ||
            Self.hasNonNullParam(params, "pane_id")
        if hasExplicitWorkspaceContext {
            let context = eventFocusedContext(params: params)
            guard let workspaceId = context.workspaceId else {
                throw EventsScopeError(message: "Event scope workspace context was not found")
            }
            return workspaceId
        }
        if let callerWorkspaceId = eventCallerUUID(params: params, key: "workspace_id") { return callerWorkspaceId }
        if let callerSurfaceId = eventCallerUUID(params: params, key: "surface_id") ??
            eventCallerUUID(params: params, key: "tab_id") {
            return eventWorkspaceId(surfaceId: callerSurfaceId)
        }
        return eventFocusedContext(params: params).workspaceId
    }

    private nonisolated func resolveEventsSurfaceId(params: [String: Any]) throws -> UUID? {
        if Self.hasNonNullParam(params, "surface_id") {
            guard let surfaceId = eventUUID(params: params, key: "surface_id") else {
                throw EventsScopeError(message: "Missing or invalid surface_id")
            }
            return surfaceId
        }
        if Self.hasNonNullParam(params, "tab_id") {
            guard let surfaceId = eventUUID(params: params, key: "tab_id") else {
                throw EventsScopeError(message: "Missing or invalid tab_id")
            }
            return surfaceId
        }
        let hasExplicitSurfaceContext = Self.hasNonNullParam(params, "window_id") ||
            Self.hasNonNullParam(params, "workspace_id") ||
            Self.hasNonNullParam(params, "pane_id")
        if hasExplicitSurfaceContext {
            let context = eventFocusedContext(params: params)
            guard let surfaceId = context.surfaceId else {
                throw EventsScopeError(message: "Event scope surface context was not found")
            }
            return surfaceId
        }
        if let callerSurfaceId = eventCallerUUID(params: params, key: "surface_id") ??
            eventCallerUUID(params: params, key: "tab_id") {
            return callerSurfaceId
        }
        return eventFocusedContext(params: params).surfaceId
    }

    private nonisolated func resolveEventsPaneId(params: [String: Any]) throws -> UUID? {
        if Self.hasNonNullParam(params, "pane_id") {
            guard let paneId = eventUUID(params: params, key: "pane_id") else {
                throw EventsScopeError(message: "Missing or invalid pane_id")
            }
            return paneId
        }
        let hasExplicitPaneContext = Self.hasNonNullParam(params, "window_id") ||
            Self.hasNonNullParam(params, "workspace_id") ||
            Self.hasNonNullParam(params, "surface_id") ||
            Self.hasNonNullParam(params, "tab_id")
        if hasExplicitPaneContext {
            let context = eventFocusedContext(params: params)
            guard let paneId = context.paneId else {
                throw EventsScopeError(message: "Event scope pane context was not found")
            }
            return paneId
        }
        if let callerPaneId = eventCallerUUID(params: params, key: "pane_id") { return callerPaneId }
        return eventFocusedContext(params: params).paneId
    }

    private nonisolated func eventCallerUUID(params: [String: Any], key: String) -> UUID? {
        guard let caller = params["caller"] as? [String: Any] else { return nil }
        return eventUUIDAny(caller[key])
    }

    private nonisolated func eventUUID(params: [String: Any], key: String) -> UUID? {
        v2MainSync { v2UUID(params, key) }
    }

    private nonisolated func eventUUIDAny(_ raw: Any?) -> UUID? {
        v2MainSync { v2UUIDAny(raw) }
    }

    private nonisolated func eventFocusedContext(
        params: [String: Any]
    ) -> (windowId: UUID?, workspaceId: UUID?, surfaceId: UUID?, paneId: UUID?) {
        let tabManager = eventTabManager(params: params)
        return v2MainSync {
            guard let tabManager else {
                return (nil, nil, nil, nil)
            }
            let windowId = AppDelegate.shared?.windowId(for: tabManager)
            let workspaceId = v2UUID(params, "workspace_id") ?? tabManager.selectedTabId
            guard let workspaceId,
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                return (windowId, nil, nil, nil)
            }
            return (
                windowId,
                workspaceId,
                workspace.focusedPanelId,
                workspace.bonsplitController.focusedPaneId?.id
            )
        }
    }

    private nonisolated func eventTabManager(params: [String: Any]) -> TabManager? {
        v2MainSync {
            if Self.hasNonNullParam(params, "window_id") {
                guard let windowId = v2UUID(params, "window_id") else { return nil }
                return AppDelegate.shared?.tabManagerFor(windowId: windowId)
            }
            if Self.hasNonNullParam(params, "workspace_id") {
                guard let workspaceId = v2UUID(params, "workspace_id") else { return nil }
                return AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
            }
            if Self.hasNonNullParam(params, "surface_id") {
                guard let surfaceId = v2UUID(params, "surface_id") else { return nil }
                return AppDelegate.shared?.locateSurface(surfaceId: surfaceId)?.tabManager
            }
            if Self.hasNonNullParam(params, "tab_id") {
                guard let surfaceId = v2UUID(params, "tab_id") else { return nil }
                return AppDelegate.shared?.locateSurface(surfaceId: surfaceId)?.tabManager
            }
            if Self.hasNonNullParam(params, "pane_id") {
                guard let paneId = v2UUID(params, "pane_id") else { return nil }
                return v2LocatePane(paneId)?.tabManager
            }
            if let workspaceId = eventCallerUUID(params: params, key: "workspace_id") {
                return AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
            }
            if let surfaceId = eventCallerUUID(params: params, key: "surface_id") ??
                eventCallerUUID(params: params, key: "tab_id") {
                return AppDelegate.shared?.locateSurface(surfaceId: surfaceId)?.tabManager
            }
            if let paneId = eventCallerUUID(params: params, key: "pane_id") {
                return v2LocatePane(paneId)?.tabManager
            }
            return AppDelegate.shared?.currentScriptableMainWindow()?.tabManager
        }
    }

    private nonisolated func eventWindowId(workspaceId: UUID) -> UUID? {
        v2MainSync {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { return nil }
            return AppDelegate.shared?.windowId(for: tabManager)
        }
    }

    private nonisolated func eventWorkspaceId(surfaceId: UUID) -> UUID? {
        v2MainSync { AppDelegate.shared?.locateSurface(surfaceId: surfaceId)?.workspaceId }
    }

    private nonisolated func eventWorkspaceIds(windowId: UUID) -> Set<String> {
        v2MainSync {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(windowId: windowId) else { return [] }
            return Set(tabManager.tabs.map { $0.id.uuidString })
        }
    }

    private nonisolated static func stringSet(_ value: Any?) -> Set<String> {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let values = value as? [String] {
            return Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        if let values = value as? [Any] {
            return Set(values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        return []
    }

    private nonisolated static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private nonisolated static func hasNonNullParam(_ params: [String: Any], _ key: String) -> Bool {
        guard let value = params[key] else { return false }
        return !(value is NSNull)
    }

    private nonisolated static func boolParam(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if number.compare(NSNumber(value: 0)) == .orderedSame { return false }
            if number.compare(NSNumber(value: 1)) == .orderedSame { return true }
            return nil
        }
        guard let string = value as? String else { return nil }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    private nonisolated static func socketPeerClosed(_ socket: Int32) -> Bool {
        var byte: UInt8 = 0
        let result = recv(socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if result == 0 {
            return true
        }
        if result > 0 {
            return false
        }
        let errorCode = errno
        return errorCode != EAGAIN && errorCode != EWOULDBLOCK && errorCode != EINTR
    }
}
