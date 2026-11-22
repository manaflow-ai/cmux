import CoreGraphics
import class CmuxNextDaemon.ScreenModel
import CmuxNextSettings

/// `debug.screens`: per window, the shown workspace's screens and the screen
/// bar as the user sees it (visible or not, its frame, tab titles, the
/// selected screen, group chips), so automation can check the bar appears at
/// two screens and hides at one without a screenshot.
enum DebugScreens {
    static func report(services: AppServices) -> JSONValue {
        let windows: [JSONValue] = services.windows.controllers.compactMap { controller in
            guard let content = controller.content else { return nil }
            return window(controller.state.id, content)
        }
        return .object(["windows": .array(windows)])
    }

    private static func window(_ id: String, _ content: WorkspaceContentController) -> JSONValue {
        let bar: ScreenBarController? = content.screenBar
        let visible = content.contentView.showsBar && !(bar?.view.isHidden ?? true)
        let tabs: [JSONValue] = (bar?.model.orderedTabs ?? []).map { .string($0.title) }
        let groups: [JSONValue] = (bar?.model.groups ?? []).map { group in
            .object(["id": .string(group.id.rawValue), "name": .string(group.name),
                     "color": .string(group.colorToken.rawValue), "collapsed": .bool(group.isCollapsed)])
        }
        var result: [String: JSONValue] = [:]
        result["window"] = .string(id)
        result["workspace"] = .string(content.workspace.id)
        result["screens"] = .array(content.workspace.screens.map(screen))
        result["active_screen"] = content.layoutModel.activeScreenID.map { .string($0.rawValue) } ?? .null
        result["bar_visible"] = .bool(visible)
        result["bar_frame"] = rect(bar?.view.frame ?? .zero)
        result["layout_frame"] = rect(content.layoutView.frame)
        result["tabs"] = .array(tabs)
        result["selected"] = bar?.model.selectedID.map { .string($0.rawValue) } ?? .null
        result["groups"] = .array(groups)
        return .object(result)
    }

    private static func screen(_ screen: ScreenModel) -> JSONValue {
        var result: [String: JSONValue] = [:]
        result["id"] = .string(screen.id)
        result["name"] = screen.name.map(JSONValue.string) ?? .null
        result["color"] = screen.color.map(JSONValue.string) ?? .null
        result["icon"] = screen.icon.map(JSONValue.string) ?? .null
        result["pinned"] = .bool(screen.pinned)
        result["group"] = screen.group.map { .string($0.rawValue) } ?? .null
        return .object(result)
    }

    private static func rect(_ frame: CGRect) -> JSONValue {
        .array([frame.minX, frame.minY, frame.width, frame.height].map { .number(Double($0)) })
    }
}
