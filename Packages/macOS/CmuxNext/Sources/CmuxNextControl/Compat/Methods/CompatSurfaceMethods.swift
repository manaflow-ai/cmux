import CmuxNextDaemon
import Foundation

/// `surface.*` and `tab.action`: tabs live in cmux-tui; selection and focus
/// are App intents.
enum CompatSurfaceMethods {
    static let table: [String: CompatHandler] = [
        "surface.list": .async(list),
        "surface.current": .async(current),
        "surface.create": .async(create),
        "surface.split": .async(split),
        "surface.close": .async(close),
        "surface.focus": .async(focus),
        "surface.move": .async(move),
        "surface.reorder": .async(move),
        "surface.health": .async(health),
        "surface.action": .async(CompatTabActions.run),
        "tab.action": .async(CompatTabActions.run),
    ]

    static func list(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let target = call.target(world)
        let workspace = try target.workspace()
        var result = CompatJSON.ids(window: try target.window(), workspace: workspace)
        result["surfaces"] = .array(world.orderedSurfaces(in: workspace).map { .object(CompatJSON.surface($0, in: world)) })
        return .object(result)
    }

    static func current(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let target = call.target(world)
        let surface = try target.surface()
        var result = CompatJSON.ids(window: try target.window(), workspace: world.workspace(surface.workspaceUUID),
                                    pane: world.panes[surface.paneUUID], surface: surface)
        result["surface_type"] = .string(surface.typeName)
        return .object(result)
    }

    static func create(_ call: CompatCall) async throws -> JSON {
        if call.string("placement")?.lowercased() == "dock" {
            throw CompatErrors.unsupported("dock panes do not exist in cmux-next", method: call.method)
        }
        if call.string("provider_id") ?? call.string("provider") != nil {
            throw CompatErrors.unsupported("surface providers are not supported yet", method: call.method)
        }
        let world = try await call.world()
        let kind = try CompatCreate.kind(call)
        let pane = try call.target(world).pane()
        let surface = try await CompatCreate.newTab(kind, in: pane, call: call)
        return try await CompatCreate.result(call, surface: surface, kind: kind)
    }

    static func split(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let kind = try CompatCreate.kind(call)
        let edge = try CompatCreate.edge(call.string("direction"), method: call.method)
        let source = try call.target(world).pane()
        let surface = try await CompatCreate.split(kind, from: source, edge: edge, call: call)
        return try await CompatCreate.result(call, surface: surface, kind: kind)
    }

    static func close(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let target = call.target(world)
        let surface = try target.surface()
        try await closeTab(surface, service: call.service)
        return .object(CompatJSON.ids(window: try target.window(), workspace: world.workspace(surface.workspaceUUID), surface: surface))
    }

    /// Terminals close through `close-terminal` (ends the process); other
    /// tabs through `close-surface`, like the App's tab strip.
    static func closeTab(_ surface: CompatWorld.Surface, service: CompatService) async throws {
        let handle = surface.handle
        if surface.isTerminal, let terminal = surface.tab.terminalID.map(TerminalID.init(rawValue:)) {
            try await service.daemon("close-terminal") { try await $0.closeTerminal(terminal) }
        } else {
            try await service.daemon("close-surface") { try await $0.closeTab(handle) }
        }
    }

    static func focus(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        guard call.string("surface_id") ?? call.string("tab_id") != nil else { throw CompatErrors.invalid("Missing or invalid surface_id") }
        let target = call.target(world)
        let surface = try target.surface()
        let window = try target.window()
        try await select(surface, in: world, window: window, call: call)
        return .object(CompatJSON.ids(window: window, workspace: world.workspace(surface.workspaceUUID), surface: surface))
    }

    static func select(_ surface: CompatWorld.Surface, in world: CompatWorld, window: CompatWorld.Window?, call: CompatCall) async throws {
        try await call.perform(.selectTab(tabID: surface.modelID, paneID: world.panes[surface.paneUUID]?.modelID ?? "",
                                             workspaceID: world.workspace(surface.workspaceUUID)?.modelID ?? "",
                                             windowID: window?.modelID))
    }

    /// `surface.move` / `surface.reorder`: to a pane (optionally at an index
    /// or next to an anchor surface), or into another workspace.
    static func move(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let refs = call.service.refs
        guard let raw = call.string("surface_id") ?? call.string("tab_id") else { throw CompatErrors.missing("surface_id", call.method) }
        let surface = try world.resolveSurface(raw, in: nil, refs: refs)
        let handle = surface.handle
        var destination = world.panes[surface.paneUUID]
        var index = call.int("index")
        if let anchorRaw = call.string("before_surface_id") ?? call.string("after_surface_id") {
            let anchor = try world.resolveSurface(anchorRaw, in: nil, refs: refs)
            if call.method == "surface.reorder", anchor.paneUUID != surface.paneUUID {
                throw CompatErrors.invalid("Anchor surface must be in the same pane")
            }
            destination = world.panes[anchor.paneUUID]
            let before = call.string("before_surface_id") != nil
            var anchorIndex = anchor.indexInPane + (before ? 0 : 1)
            if anchor.paneUUID == surface.paneUUID, surface.indexInPane < anchorIndex { anchorIndex -= 1 }
            index = anchorIndex
        } else if let paneRaw = call.string("pane_id") {
            destination = try world.resolvePane(paneRaw, in: nil, refs: refs)
        } else if call.method == "surface.move", let workspaceRaw = call.string("workspace_id") {
            let workspace = try world.resolveWorkspace(workspaceRaw, refs: refs)
            let workspaceHandle = workspace.handle
            _ = try await call.service.daemon("move-tab-to-workspace") { try await $0.moveTab(handle, toWorkspace: workspaceHandle) }
            return try await moved(call, surface: surface)
        } else if call.method == "surface.move", call.string("window_id") != nil {
            throw CompatErrors.unsupported("windows do not own workspaces in cmux-next; move to a workspace or pane", method: call.method)
        }
        guard let destination else { throw CompatErrors.notFound("pane", "destination") }
        let paneHandle = destination.handle
        let target = index ?? destination.surfaceUUIDs.count
        _ = try await call.service.daemon("move-tab") { try await $0.moveTab(handle, to: paneHandle, index: target) }
        return try await moved(call, surface: surface)
    }

    static func moved(_ call: CompatCall, surface: CompatWorld.Surface) async throws -> JSON {
        let world = try await call.world()
        let now = world.surfaces[surface.uuid] ?? world.surfaces.values.first { $0.handle == surface.handle } ?? surface
        if call.bool("focus") == true { try await select(now, in: world, window: world.activeWindow, call: call) }
        return .object(CompatJSON.ids(window: world.activeWindow, workspace: world.workspace(now.workspaceUUID),
                                      pane: world.panes[now.paneUUID], surface: now))
    }

    static func health(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let target = call.target(world)
        let workspace = try target.workspace()
        let shown = Set(world.windows.compactMap(\.workspaceUUID))
        var result = CompatJSON.ids(window: try target.window(), workspace: workspace)
        result["surfaces"] = .array(world.orderedSurfaces(in: workspace).map { surface in
            ["id": .string(surface.uuid), "ref": .string(surface.ref), "index": JSON(surface.index),
             "type": .string(surface.typeName), "in_window": .bool(shown.contains(workspace.uuid) && surface.selected),
             "exited": .bool(surface.tab.dead)]
        })
        return .object(result)
    }
}
