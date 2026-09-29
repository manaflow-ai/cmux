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
    static func create(_ call: CompatCall) async throws -> JSON {
        if call.params["layout"].map({ !$0.isNull }) == true {
            throw CompatErrors.unsupported("workspace.create layout is not supported yet; create, then split", method: call.method)
        }
        let service = call.service
        let key = WorkspaceKey.generate()
        let title = call.string("title").map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let cwd = try CompatSpawn.workingDirectory(call)
        let command = CompatSpawn.command(call)
        let terminalID = TerminalID.generate()
        let workspaceUUID = CompatUUID.canonical(key.rawValue) ?? key.rawValue
        let env = await CompatSpawn.environment(call, workspaceUUID: workspaceUUID,
                                                surfaceUUID: CompatUUID.fromHex(Substring(terminalID.rawValue)))
        let created = try await service.daemon("create-workspace") { connection in
            try await connection.request(CreateWorkspaceRequest(name: title, key: key, mutation: connection.mutation()))
        }
        _ = try await service.daemon("create-terminal") { connection in
            try await connection.request(CreateTerminalRequest(
                workspace: .key(created.key), command: command, cwd: cwd ?? NSHomeDirectory(), name: nil, size: nil,
                terminalID: terminalID, env: env, mutation: connection.mutation()))
        }
        if let groupRaw = call.string("group_id") {
            _ = try await service.daemon("move-workspace-to-group") { try await $0.moveWorkspace(created.key, toGroup: WorkspaceGroupID(rawValue: groupRaw)) }
        }
        var world = try await call.world()
        let window = try? call.target(world).window()
        if call.wantsFocus {
            try await call.perform(.showWorkspace(workspaceID: created.key.rawValue, windowID: window?.modelID))
            world = try await call.world()
        }
        let workspace = world.workspaces.first { $0.key == created.key }
        let surface = workspace.flatMap { world.orderedSurfaces(in: $0).first }
        if let input = call.string("initial_input"), let surface {
            try await CompatTerminalMethods.send(input, to: surface, service: service)
        }
        var result = CompatJSON.ids(window: window, workspace: workspace, surface: surface)
        result["group_id"] = workspace?.group.map(JSON.string) ?? .null
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
        guard let key = workspace.key else { throw CompatErrors.unsupported("the bundled cmux-tui lacks workspace-registry-v1") }
        let window = world.window(workspace.windowUUIDs.first) ?? world.activeWindow
        _ = try await call.service.daemon("close-workspace") { try await $0.closeWorkspace(key) }
        return .object(CompatJSON.ids(window: window, workspace: workspace))
    }

    static func rename(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let workspace = try call.target(world).workspace()
        guard let title = call.string("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw CompatErrors.invalid("Missing or invalid title")
        }
        guard let key = workspace.key else { throw CompatErrors.unsupported("the bundled cmux-tui lacks workspace-registry-v1") }
        _ = try await call.service.daemon("rename-workspace") { try await $0.renameWorkspace(key, to: title) }
        if workspace.customTitle != nil {
            // A sidebar title override would hide the new name.
            _ = try? await call.service.daemon("set-workspace-metadata") { try await $0.setWorkspaceMetadata(key, title: .clear) }
        }
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
