import CmuxNextDaemon
import Foundation

/// `pane.*`: layout forwards to cmux-tui; focus is an App intent.
enum CompatPaneMethods {
    static let table: [String: CompatHandler] = [
        "pane.list": .async(list),
        "pane.surfaces": .async(surfaces),
        "pane.focus": .async(focus),
        "pane.create": .async(create),
        "pane.swap": .async(swap),
    ]

    static func list(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let target = call.target(world)
        let workspace = try target.workspace()
        var result = CompatJSON.ids(window: try target.window(), workspace: workspace)
        result["panes"] = .array(world.orderedPanes(in: workspace).map { .object(CompatJSON.pane($0, in: world)) })
        return .object(result)
    }

    static func surfaces(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let target = call.target(world)
        let pane = try target.pane()
        let workspace = world.workspace(pane.workspaceUUID)
        var result = CompatJSON.ids(window: try target.window(), workspace: workspace, pane: pane)
        result["surfaces"] = .array(world.orderedSurfaces(in: pane).map { surface in
            ["id": .string(surface.uuid), "ref": .string(surface.ref), "index": JSON(surface.indexInPane),
             "title": .string(surface.title), "type": .string(surface.typeName), "selected": .bool(surface.selected)]
        })
        return .object(result)
    }

    static func focus(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        guard call.string("pane_id") != nil else { throw CompatErrors.invalid(ControlStrings.format("control.error.missingOrInvalidParam", "Missing or invalid %@", "pane_id")) }
        let target = call.target(world)
        let pane = try target.pane()
        guard let workspace = world.workspace(pane.workspaceUUID) else { throw CompatErrors.notFound("workspace", pane.workspaceUUID) }
        let window = try target.window()
        try await call.perform(.focusPane(paneID: pane.modelID, workspaceID: workspace.modelID, windowID: window?.modelID))
        return .object(CompatJSON.ids(window: window, workspace: workspace, pane: pane))
    }

    /// New pane beside the source surface's pane (default: focused).
    static func create(_ call: CompatCall) async throws -> JSON {
        if call.string("placement")?.lowercased() == "dock" {
            throw CompatErrors.unsupported(ControlStrings.text("control.error.noDockPanes", "dock panes do not exist in cmux-next"), method: call.method)
        }
        let world = try await call.world()
        let kind = try CompatCreate.kind(call)
        let edge = try CompatCreate.edge(call.string("direction") ?? "right", method: call.method)
        let source = try call.target(world).pane()
        let surface = try await CompatCreate.split(kind, from: source, edge: edge, call: call)
        return try await CompatCreate.result(call, surface: surface, kind: kind)
    }

    static func swap(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let target = call.target(world)
        let pane = try target.pane()
        guard let raw = call.string("target_pane_id") else { throw CompatErrors.missing("target_pane_id", call.method) }
        let other = try world.resolvePane(raw, in: world.workspace(pane.workspaceUUID), refs: call.service.refs)
        let handle = pane.handle
        let otherHandle = other.handle
        try await call.service.daemon("swap-pane") { try await $0.swapPane(handle, with: .pane(otherHandle)) }
        return .object(CompatJSON.ids(window: try target.window(), workspace: world.workspace(pane.workspaceUUID), pane: pane))
    }
}
