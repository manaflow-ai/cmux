import CmuxNextDaemon
import Foundation

/// `tab.action` / `surface.action` (`cmux rename-tab`, `cmux tab-action`).
enum CompatTabActions {
    static let supported = ["rename", "clear_name", "pin", "unpin", "close", "close_others", "close_left", "close_right",
                            "move_to_new_workspace"]

    static func run(_ call: CompatCall) async throws -> JSON {
        guard let action = call.string("action")?.lowercased().replacingOccurrences(of: "-", with: "_"), !action.isEmpty else {
            throw CompatErrors.invalid(ControlStrings.text("control.error.missingAction", "Missing action"))
        }
        let world = try await call.world()
        let target = call.target(world)
        let surface = try target.surface()
        let service = call.service
        let tab = CompatTargets.tab(surface)
        var title: JSON = .null
        switch action {
        case "rename":
            guard let text = call.string("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw CompatErrors.invalid(ControlStrings.format("control.error.missingOrInvalidParam", "Missing or invalid %@", "title"))
            }
            try await service.runAction("renameTab", target: tab, arguments: ["name": .string(text)], call: call)
            title = .string(text)
        case "clear_name":
            try await service.runAction("palette.clearTabName", target: tab, call: call)
        case "pin", "unpin":
            if surface.tab.pinned != (action == "pin") { try await service.runAction("palette.toggleTabPin", target: tab, call: call) }
        case "close":
            try await CompatSurfaceMethods.closeTab(surface, call: call)
        case "close_others", "close_left", "close_right":
            guard let pane = world.panes[surface.paneUUID] else { throw CompatErrors.notFound("pane", surface.paneUUID) }
            let others = world.orderedSurfaces(in: pane).filter { other in
                switch action {
                case "close_left": other.indexInPane < surface.indexInPane
                case "close_right": other.indexInPane > surface.indexInPane
                default: other.uuid != surface.uuid
                }
            }
            for other in others { try await CompatSurfaceMethods.closeTab(other, call: call) }
        case "move_to_new_workspace":
            try await service.runAction("palette.moveTabToNewWorkspace", target: tab, call: call)
        default:
            throw CompatErrors.invalid(ControlStrings.format("control.error.unknownTabAction", "Unknown tab action %@", action))
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
