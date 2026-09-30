import CmuxNextDaemon
import Foundation

/// Old-app JSON shapes for world objects (keys verified against the old
/// `TerminalController` / `CmuxControlSocket` handlers).
enum CompatJSON {
    /// `<kind>_id` + `<kind>_ref` pairs; nil objects encode as null.
    static func ids(window: CompatWorld.Window? = nil, workspace: CompatWorld.Workspace? = nil,
                    pane: CompatWorld.Pane? = nil, surface: CompatWorld.Surface? = nil,
                    include: Set<String> = ["window", "workspace"]) -> [String: JSON] {
        var out: [String: JSON] = [:]
        func put(_ kind: String, _ uuid: String?, _ ref: String?) {
            out["\(kind)_id"] = uuid.map(JSON.string) ?? .null
            out["\(kind)_ref"] = ref.map(JSON.string) ?? .null
        }
        if include.contains("window") || window != nil { put("window", window?.uuid, window?.ref) }
        if include.contains("workspace") || workspace != nil { put("workspace", workspace?.uuid, workspace?.ref) }
        if include.contains("pane") || pane != nil { put("pane", pane?.uuid, pane?.ref) }
        if include.contains("surface") || surface != nil { put("surface", surface?.uuid, surface?.ref) }
        if let named = surface?.session ?? pane?.session ?? workspace?.session {
            out.merge(sessionFields(named)) { _, new in new }
        }
        return out
    }

    /// `session_id` (the session UUID; the home session's when the App
    /// reported one), `session` (the qualifier its refs carry; null for
    /// home) and `machine` (the machine name) of an object's session
    /// (plans/cmux-next/data-model.md 1.3).
    static func sessionFields(_ session: CompatWorld.Session?) -> [String: JSON] {
        [
            "session_id": session.map { .string($0.id) } ?? .null,
            "session": session.flatMap { $0.isHome ? nil : JSON.string($0.qualifier) } ?? .null,
            "machine": session?.machineName.map(JSON.string) ?? .null,
        ]
    }

    /// `system.sessions` item.
    static func session(_ session: CompatWorld.Session, in world: CompatWorld) -> [String: JSON] {
        let key = session.isHome ? nil : session.id
        return [
            "id": .string(session.id), "qualifier": session.isHome ? .null : .string(session.qualifier),
            "home": .bool(session.isHome), "machine_id": .string(session.machineID),
            "machine": session.machineName.map(JSON.string) ?? .null, "session_name": session.sessionName.map(JSON.string) ?? .null,
            "state": .string(session.state), "transport": .string(session.transport),
            "workspace_count": JSON(world.workspaces.filter { $0.sessionID == key }.count),
        ]
    }

    static func window(_ window: CompatWorld.Window, in world: CompatWorld) -> [String: JSON] {
        let shown = world.workspace(window.workspaceUUID)
        return [
            "id": .string(window.uuid), "ref": .string(window.ref), "index": JSON(window.index),
            "key": .bool(window.isKey), "visible": .bool(window.isVisible), "hidden": .bool(window.isHidden),
            // What its sidebar shows: the current room's workspaces a machine reports.
            "workspace_count": JSON(window.visibleWorkspaceUUIDs.count),
            "workspace_ids": .array(window.visibleWorkspaceUUIDs.map(JSON.string)),
            "workspace_refs": .array(window.visibleWorkspaceUUIDs.compactMap { world.workspace($0)?.ref }.map(JSON.string)),
            "selected_workspace_id": shown.map { .string($0.uuid) } ?? .null,
            "selected_workspace_ref": shown.map { .string($0.ref) } ?? .null,
        ]
    }

    static func workspace(_ workspace: CompatWorld.Workspace, selected: Bool, in world: CompatWorld) -> [String: JSON] {
        let focus = world.focus(in: workspace)
        return [
            "id": .string(workspace.uuid), "ref": .string(workspace.ref), "index": JSON(workspace.index),
            "title": .string(workspace.title),
            "custom_title": workspace.customTitle.map(JSON.string) ?? .null,
            "has_custom_title": .bool(workspace.customTitle != nil),
            "description": .null, "selected": .bool(selected), "pinned": false,
            "listening_ports": [], "remote": .null,
            "current_directory": focus.surface?.tab.cwd.map(JSON.string) ?? .null,
            "custom_color": workspace.color.map(JSON.string) ?? .null,
            "unread_count": JSON(workspace.unreadCount),
        ].merging(sessionFields(workspace.session)) { _, new in new }
    }

    static func pane(_ pane: CompatWorld.Pane, in world: CompatWorld) -> [String: JSON] {
        let surfaces = world.orderedSurfaces(in: pane)
        let selected = world.surfaces[pane.selectedSurfaceUUID ?? ""]
        return [
            "id": .string(pane.uuid), "ref": .string(pane.ref), "index": JSON(pane.index),
            "focused": .bool(pane.focused),
            "surface_ids": .array(surfaces.map { .string($0.uuid) }),
            "surface_refs": .array(surfaces.map { .string($0.ref) }),
            "selected_surface_id": selected.map { .string($0.uuid) } ?? .null,
            "selected_surface_ref": selected.map { .string($0.ref) } ?? .null,
            "surface_count": JSON(surfaces.count),
            "zoomed": .bool(pane.zoomed),
        ].merging(sessionFields(pane.session)) { _, new in new }
    }

    /// `surface.list` / `system.tree` surface item.
    static func surface(_ surface: CompatWorld.Surface, in world: CompatWorld) -> [String: JSON] {
        let pane = world.panes[surface.paneUUID]
        var item: [String: JSON] = [
            "id": .string(surface.uuid), "ref": .string(surface.ref), "index": JSON(surface.index),
            "type": .string(surface.typeName), "title": .string(surface.title),
            "focused": .bool(surface.focused), "selected": .bool(surface.selected),
            "selected_in_pane": .bool(surface.selected),
            "pane_id": pane.map { .string($0.uuid) } ?? .null, "pane_ref": pane.map { .string($0.ref) } ?? .null,
            "index_in_pane": JSON(surface.indexInPane),
            "url": surface.isBrowser ? .string(surface.tab.url ?? "") : .null,
            "tty": .null, "pinned": .bool(surface.tab.pinned),
            "current_directory": surface.tab.cwd.map(JSON.string) ?? .null,
            "git_branch": surface.tab.gitBranch.map(JSON.string) ?? .null,
            "terminal_id": surface.tab.terminalID.map { .string(CompatUUID.fromHex(Substring($0)) ?? $0) } ?? .null,
            "exited": .bool(surface.tab.dead),
        ]
        item.merge(sessionFields(surface.session)) { _, new in new }
        return item
    }

    /// Focus/caller object of `system.identify`.
    static func focusObject(window: CompatWorld.Window?, workspace: CompatWorld.Workspace?,
                            pane: CompatWorld.Pane?, surface: CompatWorld.Surface?) -> JSON {
        var out = ids(window: window, workspace: workspace, pane: pane, surface: surface, include: ["window", "workspace", "pane", "surface"])
        out["tab_id"] = out["surface_id"]
        out["tab_ref"] = out["surface_ref"]
        out["surface_type"] = surface.map { .string($0.typeName) } ?? .null
        out["is_browser_surface"] = .bool(surface?.isBrowser == true)
        return .object(out)
    }

    /// `window_id`/`window_ref` for an App window model id (a window the
    /// published snapshot may not list yet).
    static func windowIDs(modelID: String, refs: CompatRefRegistry) -> [String: JSON] {
        let uuid = CompatUUID.canonical(modelID) ?? CompatUUID.hashed("window:" + modelID)
        return ["window_id": .string(uuid), "window_ref": .string(refs.ref(.window, uuid))]
    }

    static func iso8601(ms: UInt64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
