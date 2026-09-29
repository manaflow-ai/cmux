import CmuxNextDaemon
import Foundation

/// Tab and pane creation shared by `surface.create`, `surface.split`,
/// `pane.create`, and `browser.open_split`.
enum CompatCreate {
    enum Kind: String {
        case terminal, browser
    }

    static func kind(_ call: CompatCall) throws -> Kind {
        switch call.string("type")?.lowercased().trimmingCharacters(in: .whitespaces) {
        case nil, "", "terminal", "pty": return .terminal
        case "browser", "web": return .browser
        case let other?:
            throw CompatErrors.unsupported("\(other) panes (only terminal and browser exist in cmux-next)", method: call.method)
        }
    }

    static func edge(_ raw: String?, method: String) throws -> PaneEdge {
        switch raw?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "right", "r": return .right
        case "left", "l": return .left
        case "down", "d", "bottom": return .bottom
        case "up", "u", "top": return .top
        default: throw CompatErrors.invalid("Missing or invalid direction (left|right|up|down)")
        }
    }

    /// A new tab in `pane` through the `newSurface` / `openBrowser` actions.
    /// Returns its surface handle.
    static func newTab(_ kind: Kind, in pane: CompatWorld.Pane, call: CompatCall) async throws -> SurfaceID {
        let before = try await call.world()
        switch kind {
        case .browser:
            var arguments: [String: ControlValue] = [:]
            if let url = call.string("url"), !url.isEmpty { arguments["url"] = .string(url) }
            try await call.service.runAction("openBrowser", target: CompatTargets.pane(pane), arguments: arguments, call: call)
        case .terminal:
            var arguments: [String: ControlValue] = [:]
            if let cwd = try CompatSpawn.workingDirectory(call) { arguments["cwd"] = .string(cwd) }
            try await call.service.runAction("newSurface", target: CompatTargets.pane(pane), arguments: arguments, call: call)
        }
        let surface = try await created(since: before, in: pane.workspaceUUID, call: call)
        if kind == .terminal { try await runInitial(call, surface: surface) }
        return surface
    }

    /// A new pane beside `pane` holding a new tab: the `split<Edge>` actions
    /// for terminals; for browsers `openBrowser`, then `tab.moveToNewSplit`.
    static func split(_ kind: Kind, from pane: CompatWorld.Pane, edge: PaneEdge, call: CompatCall) async throws -> SurfaceID {
        let direction = switch edge {
        case .right: "right"
        case .left: "left"
        case .top: "up"
        case .bottom: "down"
        }
        guard kind == .terminal else {
            let surface = try await newTab(.browser, in: pane, call: call)
            let world = try await call.world()
            guard let tab = world.surfaces.values.first(where: { $0.handle == surface }) else {
                throw CompatErrors.notFound("surface", "created surface \(surface.rawValue)")
            }
            try await call.service.runAction("tab.moveToNewSplit", target: CompatTargets.tab(tab),
                                             arguments: ["direction": .string(direction)], call: call)
            return surface
        }
        let before = try await call.world()
        var arguments: [String: ControlValue] = [:]
        if let cwd = try CompatSpawn.workingDirectory(call) { arguments["cwd"] = .string(cwd) }
        let action = "split" + direction.prefix(1).uppercased() + direction.dropFirst()
        try await call.service.runAction(action, target: CompatTargets.pane(pane), arguments: arguments, call: call)
        let surface = try await created(since: before, in: pane.workspaceUUID, call: call)
        try await runInitial(call, surface: surface)
        return surface
    }

    /// The surface an action just created, found by diffing fresh trees.
    static func created(since before: CompatWorld, in workspaceUUID: String, call: CompatCall) async throws -> SurfaceID {
        guard let surface = try await call.world().createdSurface(since: before, in: workspaceUUID) else {
            throw ControlError(code: "internal_error", message: "\(call.method): the action ran but created no surface")
        }
        return surface.handle
    }

    /// `initial_command` for tabs the daemon spawns without a command
    /// field: typed into the new shell with a trailing newline.
    static func runInitial(_ call: CompatCall, surface: SurfaceID) async throws {
        var text = ""
        if let command = CompatSpawn.command(call) { text += command + "\n" }
        if let input = call.string("initial_input") { text += input }
        guard !text.isEmpty else { return }
        let input = text
        _ = try await call.service.daemon("send") { try await $0.send(surface, text: input) }
    }

    /// Old creation result: window, workspace, pane, surface ids plus type.
    /// Focuses the new tab when `focus` is true.
    static func result(_ call: CompatCall, surface handle: SurfaceID, kind: Kind) async throws -> JSON {
        var world = try await call.world()
        guard var surface = world.surfaces.values.first(where: { $0.handle == handle }) else {
            throw CompatErrors.notFound("surface", "created surface \(handle.rawValue)")
        }
        let window = try? call.target(world).window()
        if call.wantsFocus {
            try await call.perform(.selectTab(tabID: surface.modelID, paneID: world.panes[surface.paneUUID]?.modelID ?? "",
                                                      workspaceID: world.workspace(surface.workspaceUUID)?.modelID ?? "",
                                                      windowID: window?.modelID))
            world = try await call.world()
            surface = world.surfaces[surface.uuid] ?? surface
        }
        var result = CompatJSON.ids(window: window, workspace: world.workspace(surface.workspaceUUID),
                                    pane: world.panes[surface.paneUUID], surface: surface)
        result["type"] = .string(kind.rawValue)
        return .object(result)
    }
}
