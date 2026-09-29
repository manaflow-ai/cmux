import CmuxNextDaemon
import Foundation

/// `notification.*` over the cmux-tui notification ledger
/// (`notify`, `list-notifications`, `ack-tab-notifications`). The daemon
/// has no subtitle field, so a subtitle is folded into the body's first line.
enum CompatNotificationMethods {
    static let table: [String: CompatHandler] = [
        "notification.create": .async(create),
        "notification.create_for_target": .async(create),
        "notification.create_for_surface": .async(create),
        "notification.create_for_caller": .async(create),
        "notification.list": .async(list),
        "notification.clear": .async(clear),
        "notification.dismiss": .async(dismiss),
        "notification.mark_read": .async(dismiss),
        "notification.jump_to_unread": .async(jumpToUnread),
    ]

    static func create(_ call: CompatCall) async throws -> JSON {
        var params = call.params
        if call.method == "notification.create_for_caller" {
            params["workspace_id"] = params["preferred_workspace_id"]
            params["surface_id"] = params["preferred_surface_id"]
        }
        let world = try await call.world()
        let target = CompatTarget(world: world, refs: call.service.refs, params: params)
        if call.method == "notification.create_for_target" {
            guard target.string("workspace_id") != nil else { throw CompatErrors.invalid(ControlStrings.format("control.error.missingOrInvalidParam", "Missing or invalid %@", "workspace_id")) }
            guard target.string("surface_id") != nil else { throw CompatErrors.invalid(ControlStrings.format("control.error.missingOrInvalidParam", "Missing or invalid %@", "surface_id")) }
        }
        let workspace = try target.workspace()
        let surface: CompatWorld.Surface? = target.string("surface_id") != nil ? try target.surface(in: workspace) : world.focus(in: workspace).surface
        let title = call.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? "Notification"
        let body = [call.string("subtitle"), call.string("body")].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
        let handle = surface?.handle
        let id = try await call.service.daemon("notify") { try await $0.notify(title: title, body: body, surface: handle) }
        var result = CompatJSON.ids(window: world.window(workspace.windowUUIDs.first), workspace: workspace, surface: surface)
        result["id"] = .string(String(id.rawValue))
        return .object(result)
    }

    static func entries(_ call: CompatCall) async throws -> [ListNotificationsRequest.Entry] {
        try await call.service.daemon("list-notifications") { try await $0.notificationLedger() }
    }

    static func item(_ entry: ListNotificationsRequest.Entry, world: CompatWorld) -> JSON {
        let surface = entry.surface.flatMap { handle in world.surfaces.values.first { $0.handle == handle } }
        let workspace = world.workspace(surface?.workspaceUUID)
        var body = entry.body
        var subtitle = entry.subtitle ?? ""
        if entry.subtitle == nil, let newline = body.firstIndex(of: "\n") {
            subtitle = String(body[..<newline])
            body = String(body[body.index(after: newline)...])
        }
        return [
            "id": .string(entry.id), "title": .string(entry.title), "subtitle": .string(subtitle), "body": .string(body),
            "level": .string(entry.level.rawValue),
            "workspace_id": workspace.map { .string($0.uuid) } ?? .null, "workspace_ref": workspace.map { .string($0.ref) } ?? .null,
            "surface_id": surface.map { .string($0.uuid) } ?? .null, "surface_ref": surface.map { .string($0.ref) } ?? .null,
            "created_at": .string(CompatJSON.iso8601(ms: entry.createdAtMs)),
            "tab_title": surface.map { .string($0.title) } ?? .null, "is_read": .bool(entry.acknowledged),
        ]
    }

    static func list(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        return ["notifications": .array(try await entries(call).map { item($0, world: world) })]
    }

    /// Acknowledges unread markers: all, one workspace, or one surface.
    static func clear(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let target = call.target(world)
        var scope = Array(world.surfaces.values)
        var workspace: CompatWorld.Workspace?
        var surface: CompatWorld.Surface?
        if call.bool("caller") == true || target.string("workspace_id") != nil || target.string("tab_id") != nil {
            var params = call.params
            if call.bool("caller") == true {
                params["workspace_id"] = params["preferred_workspace_id"]
                params["surface_id"] = params["preferred_surface_id"]
            }
            let scoped = CompatTarget(world: world, refs: call.service.refs, params: params)
            let found = try scoped.workspace()
            workspace = found
            scope = world.orderedSurfaces(in: found)
            if scoped.string("surface_id") != nil {
                let one = try scoped.surface(in: found)
                surface = one
                scope = [one]
            }
        }
        let cleared = try await acknowledge(scope.filter { $0.tab.unread }, service: call.service)
        guard workspace != nil else { return ["cleared": JSON(cleared)] }
        var result = CompatJSON.ids(workspace: workspace, surface: surface, include: ["workspace", "surface"])
        result["cleared"] = true
        return .object(result)
    }

    /// Marks unread tabs read through the `palette.toggleTabUnread` action
    /// (the tab context menu's Mark Read), one tab at a time.
    @discardableResult
    static func acknowledge(_ surfaces: [CompatWorld.Surface], service: CompatService,
                            method: String = "notification.clear") async throws -> Int {
        let unread = surfaces.filter(\.tab.unread)
        for surface in unread {
            try await service.runAction("palette.toggleTabUnread", target: CompatTargets.tab(surface), connection: .inProcess,
                                        method: method, deadline: .now + CompatDeadline.controlPlane)
        }
        return unread.count
    }

    /// `notification.dismiss {id}` / `{all_read}` and `mark_read`: the
    /// ledger has no per-entry delete, so this acknowledges the entry's tab.
    static func dismiss(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let ledger = try await entries(call)
        if call.bool("all_read") == true {
            return ["dismissed": JSON(ledger.filter(\.acknowledged).count), "all_read": true]
        }
        guard let id = call.string("id") else { throw CompatErrors.missing("id", call.method) }
        guard let entry = ledger.first(where: { $0.id == id }) else {
            throw ControlError(code: "not_found", message: ControlStrings.text("control.error.notificationNotFound", "Notification not found"), data: ["id": .string(id)])
        }
        if let handle = entry.surface, let surface = world.surfaces.values.first(where: { $0.handle == handle }) {
            try await acknowledge([surface], service: call.service)
        }
        guard case .object(var result) = item(entry, world: world) else { return .null }
        result["dismissed"] = 1
        result["is_read"] = true
        return .object(result)
    }

    static func jumpToUnread(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let unread = world.workspaces.flatMap { world.orderedSurfaces(in: $0) }.first { $0.tab.unread }
        guard let unread else { return ["jumped": false] }
        try await CompatSurfaceMethods.select(unread, in: world, window: world.activeWindow, call: call)
        var result = CompatJSON.ids(window: world.activeWindow, workspace: world.workspace(unread.workspaceUUID), surface: unread)
        result["jumped"] = true
        return .object(result)
    }
}
