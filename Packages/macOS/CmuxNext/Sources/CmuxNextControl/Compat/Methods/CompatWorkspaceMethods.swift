import CmuxNextDaemon
import Foundation

/// `workspace.*`: durable state forwards to cmux-tui; which workspace a
/// window shows is an App intent.
enum CompatWorkspaceMethods {
    static let table: [String: CompatHandler] = [
        "workspace.list": .async(list),
        "workspace.current": .async(current),
        "workspace.create": .async(create),
        "workspace.select": .async(select),
        "workspace.close": .async(close),
        "workspace.rename": .async(rename),
        "workspace.next": .async({ call in try await step(call, by: 1) }),
        "workspace.previous": .async({ call in try await step(call, by: -1) }),
        "workspace.reorder": .async(reorder),
    ]

    static func list(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let window = try call.target(world).window()
        var result = CompatJSON.ids(window: window, include: ["window"])
        result["workspaces"] = .array(world.workspaces.map {
            .object(CompatJSON.workspace($0, selected: $0.uuid == (window?.workspaceUUID ?? world.workspaces.first?.uuid), in: world))
        })
        return .object(result)
    }

    static func current(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let window = try call.target(world).window()
        guard let workspace = world.currentWorkspace(window: window) else { throw CompatErrors.notFound("workspace", "selected") }
        var result = CompatJSON.ids(window: window, workspace: workspace)
        result["workspace"] = .object(CompatJSON.workspace(workspace, selected: true, in: world))
        return .object(result)
    }

    /// New workspace with one terminal. `focus` (default false) also shows it
    /// in the target window, like the old app.
    /// The `newTab` (New Workspace) action with the old params as its
    /// arguments; shown in the target window only with `focus: true`.
    static func create(_ call: CompatCall) async throws -> JSON {
        if call.params["layout"].map({ !$0.isNull }) == true {
            throw CompatErrors.unsupported("workspace.create layout is not supported yet; create, then split", method: call.method)
        }
        let service = call.service
        var arguments: [String: ControlValue] = ["focus": .bool(call.wantsFocus)]
        if let title = call.string("title")?.trimmingCharacters(in: .whitespaces), !title.isEmpty { arguments["name"] = .string(title) }
        if let cwd = try CompatSpawn.workingDirectory(call) { arguments["cwd"] = .string(cwd) }
        if let command = CompatSpawn.command(call) { arguments["command"] = .string(command) }
        let env = (call.params["initial_env"] ?? call.params["startup_environment"])?.objectValue ?? [:]
        if !env.isEmpty { arguments["env"] = .string(JSON.object(env).compactText) }
        let before = try await call.world()
        try await service.runAction("newTab", arguments: arguments, call: call)
        let world = try await call.world()
        guard let workspace = world.createdWorkspace(since: before) else {
            throw ControlError(code: "internal_error", message: "workspace.create: the action ran but created no workspace")
        }
        if let groupRaw = call.string("group_id"), let key = workspace.key {
            // No registry action places a workspace in a group by id yet.
            _ = try await service.daemon("move-workspace-to-group") { try await $0.moveWorkspace(key, toGroup: WorkspaceGroupID(rawValue: groupRaw)) }
        }
        let window = try? call.target(world).window()
        let surface = world.orderedSurfaces(in: workspace).first
        if let input = call.string("initial_input"), let surface {
            try await CompatTerminalMethods.send(input, to: surface, service: service)
        }
        var result = CompatJSON.ids(window: window, workspace: workspace, surface: surface)
        result["group_id"] = workspace.group.map(JSON.string) ?? .null
        result["group_ref"] = .null
        return .object(result)
    }

    static func select(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        guard let raw = call.string("workspace_id") else { throw CompatErrors.invalid("Missing or invalid workspace_id") }
        let workspace = try world.resolveWorkspace(raw, refs: call.service.refs)
        let window = try call.target(world).window()
        try await call.perform(.showWorkspace(workspaceID: workspace.modelID, windowID: window?.modelID))
        let after = try await call.world()
        let shownIn = after.window(window?.uuid) ?? after.window(after.workspace(workspace.uuid)?.windowUUIDs.first)
        return .object(CompatJSON.ids(window: shownIn, workspace: workspace))
    }

    static func close(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        guard let raw = call.string("workspace_id") else { throw CompatErrors.invalid("Missing or invalid workspace_id") }
        let workspace = try world.resolveWorkspace(raw, refs: call.service.refs)
        let window = world.window(workspace.windowUUIDs.first) ?? world.activeWindow
        // The old CLI's `close-workspace` is its own confirmation (it never
        // prompted), so compat passes the destructive action's `confirm`.
        try await call.service.runAction("closeWorkspace", target: CompatTargets.workspace(workspace),
                                         arguments: ["confirm": .bool(true)], call: call)
        return .object(CompatJSON.ids(window: window, workspace: workspace))
    }

    static func rename(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let workspace = try call.target(world).workspace()
        guard let title = call.string("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw CompatErrors.invalid("Missing or invalid title")
        }
        try await call.service.runAction("renameWorkspace", target: CompatTargets.workspace(workspace),
                                         arguments: ["name": .string(title)], call: call)
        var result = CompatJSON.ids(window: world.window(workspace.windowUUIDs.first) ?? world.activeWindow, workspace: workspace)
        result["title"] = .string(title)
        return .object(result)
    }

    static func step(_ call: CompatCall, by offset: Int) async throws -> JSON {
        let world = try await call.world()
        let window = try call.target(world).window()
        guard let current = world.currentWorkspace(window: window), !world.workspaces.isEmpty else {
            throw CompatErrors.notFound("workspace", "selected")
        }
        let count = world.workspaces.count
        let next = world.workspaces[((current.index + offset) % count + count) % count]
        try await call.perform(.showWorkspace(workspaceID: next.modelID, windowID: window?.modelID))
        return .object(CompatJSON.ids(window: window, workspace: next))
    }

    /// Exactly one of `index`, `before_workspace_id`, `after_workspace_id`.
    static func reorder(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let refs = call.service.refs
        let workspace = try call.target(world).workspace()
        guard let key = workspace.key else { throw CompatErrors.unsupported("the bundled cmux-tui lacks workspace-registry-v1") }
        var index: Int
        if let explicit = call.int("index") {
            index = explicit
        } else if let raw = call.string("before_workspace_id") {
            let anchor = try world.resolveWorkspace(raw, refs: refs)
            index = anchor.index > workspace.index ? anchor.index - 1 : anchor.index
        } else if let raw = call.string("after_workspace_id") {
            let anchor = try world.resolveWorkspace(raw, refs: refs)
            index = anchor.index >= workspace.index ? anchor.index : anchor.index + 1
        } else {
            throw CompatErrors.invalid("workspace.reorder requires index, before_workspace_id, or after_workspace_id")
        }
        let clamped = max(0, min(index, world.workspaces.count - 1))
        index = clamped
        _ = try await call.service.daemon("move-workspace") { try await $0.moveWorkspace(key, to: clamped) }
        var result = CompatJSON.ids(window: world.activeWindow, workspace: workspace)
        result["index"] = JSON(index)
        return .object(result)
    }
}
