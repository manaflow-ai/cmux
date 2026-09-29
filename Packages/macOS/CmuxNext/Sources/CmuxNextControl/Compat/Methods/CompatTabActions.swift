import CmuxNextDaemon
import Foundation

/// `tab.action` / `surface.action` (`cmux rename-tab`, `cmux tab-action`).
enum CompatTabActions {
    static let supported = ["rename", "clear_name", "pin", "unpin", "close", "close_others", "close_left", "close_right",
                            "move_to_new_workspace"]

    static func run(_ call: CompatCall) async throws -> JSON {
        guard let action = call.string("action")?.lowercased().replacingOccurrences(of: "-", with: "_"), !action.isEmpty else {
            throw CompatErrors.invalid("Missing action")
        }
        let world = try await call.world()
        let target = call.target(world)
        let surface = try target.surface()
        let service = call.service
        let handle = surface.handle
        var title: JSON = .null
        switch action {
        case "rename":
            guard let text = call.string("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw CompatErrors.invalid("Missing or invalid title")
            }
            try await service.daemon("rename-surface") { try await $0.renameTab(handle, to: text) }
            title = .string(text)
        case "clear_name":
            try await service.daemon("rename-surface") { try await $0.renameTab(handle, to: "") }
        case "pin", "unpin":
            let pinned = action == "pin"
            _ = try await service.daemon("set-tab-pinned") { try await $0.setTabPinned(handle, pinned) }
        case "close":
            try await CompatSurfaceMethods.closeTab(surface, service: service)
        case "close_others", "close_left", "close_right":
            guard let pane = world.panes[surface.paneUUID] else { throw CompatErrors.notFound("pane", surface.paneUUID) }
            let others = world.orderedSurfaces(in: pane).filter { other in
                switch action {
                case "close_left": other.indexInPane < surface.indexInPane
                case "close_right": other.indexInPane > surface.indexInPane
                default: other.uuid != surface.uuid
                }
            }
            for other in others { try await CompatSurfaceMethods.closeTab(other, service: service) }
        case "move_to_new_workspace":
            _ = try await service.daemon("move-tab-to-new-workspace") { try await $0.moveTabToNewWorkspace(handle) }
        default:
            throw CompatErrors.invalid("Unknown tab action \(action)")
        }
        let after = (try? await call.world()) ?? world
        let now = after.surfaces[surface.uuid] ?? surface
        var result = CompatJSON.ids(window: try target.window(), workspace: after.workspace(now.workspaceUUID),
                                    pane: after.panes[now.paneUUID], surface: now)
        result["tab_id"] = result["surface_id"]
        result["tab_ref"] = result["surface_ref"]
        result["action"] = .string(action)
        result["title"] = title
        return .object(result)
    }
}
