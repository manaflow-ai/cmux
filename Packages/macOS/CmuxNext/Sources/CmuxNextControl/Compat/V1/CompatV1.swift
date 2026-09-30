import CmuxNextDaemon
import Foundation

/// The v1 plain-text verbs the current CLI, hooks, and shell integration
/// still send (`list_windows`, `set_status`, `list_notifications`, …).
/// Replies follow the old text formats: `OK`, `ERROR: …`, or listing lines.
enum CompatV1 {
    typealias Handler = @Sendable (CompatV1Line, CompatService) async throws -> String

    static let handlers: [String: Handler] = {
        var all: [String: Handler] = [
            "list_windows": listWindows,
            "current_window": currentWindow,
            "new_window": newWindow,
            "focus_window": { line, service in try await windowIntent(line, service) { .focusWindow(windowID: $0.modelID) } },
            "close_window": { line, service in try await windowIntent(line, service) { .closeWindow(windowID: $0.modelID) } },
            "list_notifications": listNotifications,
            "clear_notifications": clearNotifications,
            "notify_target": notifyTarget,
            "notify_target_async": notifyTarget,
        ]
        all.merge(CompatV1Sidebar.handlers) { first, _ in first }
        return all
    }()

    /// Verbs answered with a typed unsupported error.
    static let unsupported: [String: String] = [
        "resize_window": "window frames are app-local; resize the window directly",
        "refresh_surfaces": "cmux-next surfaces redraw from cmux-tui deltas; nothing to refresh",
        "reload_config": "cmux-next reloads cmux.json on change; no manual reload is needed",
        "set_app_focus": "focus overrides are a debug feature of the old app",
        "simulate_app_active": "focus overrides are a debug feature of the old app",
        "iroh_diag": "iroh diagnostics are not part of cmux-next yet",
        "right_sidebar": "the right sidebar is not part of cmux-next yet",
    ]

    static func respond(_ raw: String, service: CompatService) async -> String? {
        // The journal payload is raw JSON after the verb, not shell tokens.
        if raw.hasPrefix("agent_journal_append") {
            return await CompatFeed.journalAppend(String(raw.dropFirst("agent_journal_append".count)), service: service)
        }
        let line = CompatV1Line(raw)
        if let reason = unsupported[line.verb] { return "ERROR: unsupported in cmux-next: \(reason)" }
        guard let handler = handlers[line.verb] else { return nil }
        do {
            return try await handler(line, service)
        } catch let error as ControlError {
            return "ERROR: \(error.message)"
        } catch {
            return "ERROR: \(error)"
        }
    }

    // MARK: - Windows

    static func listWindows(_ line: CompatV1Line, _ service: CompatService) async throws -> String {
        let world = try await service.world()
        // `--all` adds the windows the app keeps off screen, marked `hidden`.
        let windows = world.listedWindows(includeHidden: line.has("all") || line.has("include-hidden"))
        guard !windows.isEmpty else { return "No windows" }
        return windows.map { window in
            let marker = window.uuid == world.activeWindowUUID ? "*" : " "
            let line = "\(marker) \(window.index): \(window.uuid) selected_workspace=\(window.workspaceUUID ?? "none") workspaces=\(window.visibleWorkspaceUUIDs.count)"
            return window.isHidden ? line + " hidden" : line
        }.joined(separator: "\n")
    }

    static func currentWindow(_ line: CompatV1Line, _ service: CompatService) async throws -> String {
        let world = try await service.world()
        guard let window = world.activeWindow else { return "ERROR: No active window" }
        return window.uuid
    }

    static func newWindow(_ line: CompatV1Line, _ service: CompatService) async throws -> String {
        let result = try await service.perform(.newWindow(workspaceID: nil))
        let id = result["window_id"]?.stringValue ?? ""
        return "OK \(CompatJSON.windowIDs(modelID: id, refs: service.refs)["window_id"]?.stringValue ?? "")"
    }

    static func windowIntent(_ line: CompatV1Line, _ service: CompatService,
                             _ make: (CompatWorld.Window) -> CompatFrontendIntent) async throws -> String {
        guard let raw = line.positional.first else { return "ERROR: Missing window id" }
        let world = try await service.world()
        let window = try world.resolveWindow(raw, refs: service.refs)
        try await service.perform(make(window))
        return "OK"
    }

    // MARK: - Notifications

    static func listNotifications(_ line: CompatV1Line, _ service: CompatService) async throws -> String {
        let world = try await service.world()
        let entries = try await service.daemon("list-notifications", mutates: false) { try await $0.notificationLedger() }
        guard !entries.isEmpty else { return "No notifications" }
        return entries.enumerated().map { index, entry in
            let surface = entry.surface.flatMap { world.surface(CompatSurfaceHandle(handle: $0, session: nil)) }
            let workspace = surface?.workspaceUUID ?? CompatUUID.hashed("unattributed")
            let fields = [entry.id, workspace, surface?.uuid ?? "none", entry.acknowledged ? "read" : "unread", entry.title,
                          entry.subtitle ?? "", entry.body.replacingOccurrences(of: "\n", with: " "),
                          CompatJSON.iso8601(ms: entry.createdAtMs), surface?.title ?? ""]
            return "\(index):" + fields.map { $0.replacingOccurrences(of: "|", with: "/") }.joined(separator: "|")
        }.joined(separator: "\n")
    }

    static func clearNotifications(_ line: CompatV1Line, _ service: CompatService) async throws -> String {
        let world = try await service.world()
        var scope = Array(world.surfaces.values)
        if let tab = line.option("tab") {
            let workspace = try world.resolveWorkspace(tab, refs: service.refs)
            scope = world.orderedSurfaces(in: workspace)
            if let panel = line.option("panel") {
                scope = [try world.resolveSurface(panel, in: workspace, refs: service.refs)]
            }
        }
        try await CompatNotificationMethods.acknowledge(scope.filter { $0.tab.unread }, service: service)
        return "OK"
    }

    /// `notify_target <workspace> <surface> <title>|<subtitle>|<body>[|meta]`.
    static func notifyTarget(_ line: CompatV1Line, _ service: CompatService) async throws -> String {
        guard line.positional.count >= 3 else { return "ERROR: usage: notify_target <workspace> <surface> <title>|<subtitle>|<body>" }
        let world = try await service.world()
        let workspace = try world.resolveWorkspace(line.positional[0], refs: service.refs)
        let surface = try world.resolveSurface(line.positional[1], in: workspace, refs: service.refs)
        let payload = line.rest(after: 2)
        let fields = payload.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        let title = fields.first.flatMap { $0.isEmpty ? nil : $0 } ?? "Notification"
        let body = [fields.count > 1 ? fields[1] : "", fields.count > 2 ? fields[2] : ""].filter { !$0.isEmpty }.joined(separator: "\n")
        let handle = surface.handle
        _ = try await service.daemon("notify", session: surface.sessionID) { try await $0.notify(title: title, body: body, surface: handle) }
        return "OK"
    }
}
