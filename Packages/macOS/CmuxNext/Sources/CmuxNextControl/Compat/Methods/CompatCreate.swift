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

    /// A new tab in `pane`. Returns its surface handle.
    static func newTab(_ kind: Kind, in pane: CompatWorld.Pane, call: CompatCall) async throws -> SurfaceID {
        let service = call.service
        let handle = pane.handle
        switch kind {
        case .browser:
            let url = call.string("url").flatMap { $0.isEmpty ? nil : $0 } ?? "about:blank"
            return try await service.daemon("new-frontend-browser-tab") {
                try await $0.newFrontendBrowserTab(url: url, engine: .webkit, in: handle).surface
            }
        case .terminal:
            let options = SpawnOptions(cwd: try CompatSpawn.workingDirectory(call),
                                       env: await CompatSpawn.environment(call, workspaceUUID: pane.workspaceUUID, surfaceUUID: nil))
            let surface = try await service.daemon("new-tab") { try await $0.newTab(in: handle, options: options).surface }
            try await runInitial(call, surface: surface)
            return surface
        }
    }

    /// A new pane beside `pane` holding a new tab. Right and down terminal
    /// splits are one `split`; other cases create the tab, then
    /// `move-tab-to-split` it to the edge (the daemon has no left/up split).
    static func split(_ kind: Kind, from pane: CompatWorld.Pane, edge: PaneEdge, call: CompatCall) async throws -> SurfaceID {
        let service = call.service
        let handle = pane.handle
        if kind == .terminal, edge == .right || edge == .bottom {
            let options = SpawnOptions(cwd: try CompatSpawn.workingDirectory(call),
                                       env: await CompatSpawn.environment(call, workspaceUUID: pane.workspaceUUID, surfaceUUID: nil))
            let direction: SplitDirection = edge == .right ? .right : .down
            let surface = try await service.daemon("split") { try await $0.split(handle, direction: direction, options: options).surface }
            try await runInitial(call, surface: surface)
            return surface
        }
        let surface = try await newTab(kind, in: pane, call: call)
        _ = try await service.daemon("move-tab-to-split") { try await $0.moveTabToSplit(surface, pane: handle, edge: edge) }
        return surface
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
