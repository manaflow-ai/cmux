import CmuxNextDaemon
import Foundation

/// Handle resolution with the old app's rules: a UUID, a `kind:N` ref, or a
/// bare index (scoped to the workspace for panes and surfaces). Surfaces
/// also resolve by the UUID form of their terminal id and by raw `tab_…`
/// resource ids; workspaces by their durable key.
extension CompatWorld {
    func resolveWindow(_ raw: String, refs: CompatRefRegistry) throws -> Window {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let uuid = CompatUUID.canonical(text), let found = windows.first(where: { $0.uuid == uuid }) { return found }
        if let (kind, number) = CompatRefRegistry.parse(text) {
            guard kind == .window else { throw CompatErrors.invalid("expected a window handle, got \(text)") }
            if let uuid = refs.uuid(.window, number: number), let found = window(uuid) { return found }
        } else if let index = Int(text), let found = windows.first(where: { $0.index == index }) {
            return found
        } else if let found = windows.first(where: { $0.modelID == text }) {
            return found
        }
        throw CompatErrors.notFound("window", text)
    }

    func resolveWorkspace(_ raw: String, refs: CompatRefRegistry) throws -> Workspace {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let uuid = CompatUUID.canonical(text), let found = workspace(uuid) { return found }
        if let (kind, number) = CompatRefRegistry.parse(text) {
            guard kind == .workspace else { throw CompatErrors.invalid("expected a workspace handle, got \(text)") }
            if let uuid = refs.uuid(.workspace, number: number), let found = workspace(uuid) { return found }
        } else if let index = Int(text), let found = workspaces.first(where: { $0.index == index }) {
            return found
        } else if let found = workspaces.first(where: { $0.modelID == text }) {
            return found
        }
        throw CompatErrors.notFound("workspace", text)
    }

    func resolvePane(_ raw: String, in scope: Workspace?, refs: CompatRefRegistry) throws -> Pane {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let uuid = CompatUUID.canonical(text), let found = panes[uuid] { return found }
        if let (kind, number) = CompatRefRegistry.parse(text) {
            guard kind == .pane else { throw CompatErrors.invalid("expected a pane handle, got \(text)") }
            if let uuid = refs.uuid(.pane, number: number), let found = panes[uuid] { return found }
        } else if let index = Int(text) {
            let candidates = scope.map(orderedPanes(in:)) ?? []
            if let found = candidates.first(where: { $0.index == index }) { return found }
        } else if let found = panes.values.first(where: { $0.modelID == text }) {
            return found
        }
        throw CompatErrors.notFound("pane", text)
    }

    func resolveSurface(_ raw: String, in scope: Workspace?, refs: CompatRefRegistry) throws -> Surface {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let uuid = CompatUUID.canonical(text) {
            if let found = surfaces[uuid] { return found }
            let hex = uuid.replacingOccurrences(of: "-", with: "").lowercased()
            if let found = surfaces.values.first(where: { $0.tab.terminalID == hex }) { return found }
        }
        if let (kind, number) = CompatRefRegistry.parse(text) {
            guard kind == .surface else { throw CompatErrors.invalid("expected a surface handle, got \(text)") }
            if let uuid = refs.uuid(.surface, number: number), let found = surfaces[uuid] { return found }
        } else if let index = Int(text) {
            let candidates = scope.map(orderedSurfaces(in:)) ?? []
            if let found = candidates.first(where: { $0.index == index }) { return found }
        } else if let found = surfaces.values.first(where: {
            $0.modelID == text || $0.tab.terminalID == text
        }) {
            return found
        }
        throw CompatErrors.notFound("surface", text)
    }
}

/// Request-scoped targeting: explicit params first, then the caller's
/// focus in the target window, like the old app.
struct CompatTarget {
    let world: CompatWorld
    let refs: CompatRefRegistry
    let params: [String: JSON]

    func string(_ key: String) -> String? {
        guard let value = params[key], !value.isNull else { return nil }
        let text = (value.stringValue ?? value.compactText).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    func window() throws -> CompatWorld.Window? {
        if let raw = string("window_id") ?? string("window") { return try world.resolveWindow(raw, refs: refs) }
        return world.activeWindow
    }

    /// `workspace_id`, else the workspace of `surface_id`/`pane_id`, else the
    /// workspace the target window shows.
    func workspace() throws -> CompatWorld.Workspace {
        if let raw = string("workspace_id") ?? string("workspace") { return try world.resolveWorkspace(raw, refs: refs) }
        if let raw = string("surface_id") ?? string("tab_id") ?? string("panel_id"),
           let surface = try? world.resolveSurface(raw, in: nil, refs: refs), let found = world.workspace(surface.workspaceUUID) {
            return found
        }
        if let raw = string("pane_id"), let pane = try? world.resolvePane(raw, in: nil, refs: refs),
           let found = world.workspace(pane.workspaceUUID) {
            return found
        }
        guard let found = world.currentWorkspace(window: try window()) else { throw CompatErrors.notFound("workspace", "current") }
        return found
    }

    func pane(in workspace: CompatWorld.Workspace? = nil) throws -> CompatWorld.Pane {
        let scope = try workspace ?? self.workspace()
        if let raw = string("pane_id") ?? string("pane") { return try world.resolvePane(raw, in: scope, refs: refs) }
        if let raw = string("surface_id") ?? string("tab_id") ?? string("panel_id") {
            let surface = try world.resolveSurface(raw, in: scope, refs: refs)
            if let pane = world.panes[surface.paneUUID] { return pane }
        }
        guard let pane = world.focus(in: scope).pane else { throw CompatErrors.notFound("pane", "focused") }
        return pane
    }

    func surface(in workspace: CompatWorld.Workspace? = nil) throws -> CompatWorld.Surface {
        if let raw = string("surface_id") ?? string("tab_id") ?? string("panel_id") ?? string("surface") {
            let scope = try? workspace ?? self.workspace()
            return try world.resolveSurface(raw, in: scope, refs: refs)
        }
        if string("pane_id") != nil {
            let pane = try self.pane(in: workspace)
            if let surface = world.surfaces[pane.selectedSurfaceUUID ?? ""] { return surface }
        }
        let scope = try workspace ?? self.workspace()
        guard let surface = world.focus(in: scope).surface else { throw CompatErrors.notFound("surface", "focused") }
        return surface
    }
}
