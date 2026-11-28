import AppKit
import CmuxNextControl
import CmuxNextSettings

// DEBUG builds: `debug.tunables` (the Debug Settings window and tunable store, DebugTunables) and
// `debug.menu_item` (performs a main-menu item the way a click does, so automation proves a menu
// entry point such as Settings… without synthesizing mouse input). The Swift Settings window and
// its `debug.settings` verb went with R82 commit 6; the React Settings page is driven through
// `debug.page cmux.settings`.
extension AppControl {
    func registerSettingsDebugMethods(_ services: AppServices) {
        #if DEBUG
        service?.router.register([
            .mainActor("debug.tunables") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugTunables.handle(call.params, services: services))
            },
            .mainActor("debug.menu_item") { call in
                .value(DebugMainMenu.perform(call.params))
            },
        ])
        #endif
    }
}

#if DEBUG
/// `debug.menu_item {"title": "Settings…"}`: the first enabled main-menu item with that title (any
/// submenu), performed through its menu (`performActionForItem`, the click path). Answers the menu
/// and item titles, or an error when no enabled item has the title.
enum DebugMainMenu {
    static func perform(_ params: [String: JSONValue]) -> JSONValue {
        guard let title = params["title"]?.stringValue, let menu = NSApp.mainMenu else {
            return .object(["error": .string("title is required")])
        }
        guard let (owner, index) = find(title, in: menu) else {
            return .object(["error": .string("no enabled main-menu item titled \(title)")])
        }
        owner.update()
        guard owner.items[index].isEnabled else { return .object(["error": .string("\(title) is disabled")]) }
        owner.performActionForItem(at: index)
        return .object(["menu": .string(owner.title), "item": .string(title)])
    }

    private static func find(_ title: String, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.title == title { return (menu, index) }
            if let submenu = item.submenu, let found = find(title, in: submenu) { return found }
        }
        return nil
    }
}
#endif
