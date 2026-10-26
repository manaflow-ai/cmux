import AppKit
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings

// DEBUG builds: `debug.tunables` (the Debug Settings window and tunable store, DebugTunables) and
// `debug.menu_item` (performs a main-menu item the way a click does, so automation proves a menu
// entry point such as Settings… without synthesizing mouse input). The Swift Settings window and
// its `debug.settings` verb went with R82 commit 6; the React Settings page is driven through
// `debug.page cmux.settings`.
extension AppControl {
    func registerSettingsDebugMethods(_ services: AppServices) {
        #if DEBUG || CMUX_BENCH_HOOKS
        service?.router.register([
            .mainActor("debug.tunables") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugTunables.handle(call.params, services: services))
            },
            .mainActor("debug.menu_item") { call in
                .value(DebugMainMenu.perform(call.params))
            },
            // The host pressure popover for captures (its level is the `hostPressure.force` tunable).
            .mainActor("debug.host_pressure") { call in
                .value(HostPressureIndicatorView.debug(call.params))
            },
        ])
        #endif
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
/// `debug.menu_item {"title": "Settings…"}`: the first enabled main-menu item with that title (any
/// submenu), performed through its menu (`performActionForItem`, the click path). Every menu is
/// validated first, as opening it does, so titles that follow their target (Pin Tab or Unpin Tab)
/// match what a person sees. Answers the menu and item titles, or an error when no enabled item has
/// the title.
/// The Edit menu's undo and redo actions, declared so `debug.menu_item` names them with `#selector`.
@objc private protocol DebugEditActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

enum DebugMainMenu {
    static func perform(_ params: [String: JSONValue]) -> JSONValue {
        // `{"action": "undo:", "window_number": N}`: the menu item's action sent up the responder chain of that window's
        // focused responder, as Edit > Undo does in a key window (a test window is not key, so the menu has no target).
        if let action = params["action"]?.stringValue {
            let number = params["window_number"]?.doubleValue.map { Int($0) }
            guard let window = number.flatMap({ NSApp.window(withWindowNumber: $0) })
                    ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
                return .object(["error": .string("no window")])
            }
            // Typed selectors only: a string selector raises on an unknown name (crash ratchet dynamic_dispatch).
            let selectors: [String: Selector] = ["undo:": #selector(DebugEditActions.undo(_:)), "redo:": #selector(DebugEditActions.redo(_:))]
            guard let selector = selectors[action] else {
                return .object(["error": .string("unsupported action \(action); one of \(selectors.keys.sorted())")])
            }
            let responder: NSResponder = window.firstResponder ?? window
            let performed = responder.tryToPerform(selector, with: nil)
            return .object(["performed": .bool(performed), "window_number": .number(Double(window.windowNumber)),
                            "responder": .string(String(describing: type(of: responder)))])
        }
        guard let title = params["title"]?.stringValue, let menu = NSApp.mainMenu else {
            return .object(["error": .string("title is required")])
        }
        validate(menu)
        guard let (owner, index) = find(title, in: menu) else {
            return .object(["error": .string("no enabled main-menu item titled \(title)")])
        }
        owner.update()
        guard owner.items[index].isEnabled else { return .object(["error": .string("\(title) is disabled")]) }
        owner.performActionForItem(at: index)
        return .object(["menu": .string(owner.title), "item": .string(title)])
    }

    private static func validate(_ menu: NSMenu) {
        menu.update()
        for item in menu.items { item.submenu.map(validate) }
    }

    private static func find(_ title: String, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.title == title, item.isEnabled { return (menu, index) }
            if let submenu = item.submenu, let found = find(title, in: submenu) { return found }
        }
        return nil
    }
}
#endif

/// The App's debug method groups, one afterFirstFrame post of the control launch (p08-startup-019,
/// `ControlLaunch`); most register only in DEV builds.
extension AppControl {
    func registerAppDebugMethods(_ services: AppServices) {
        registerSettingsDebugMethods(services)
        registerPageDebugMethods(services)
        registerRemoteBrowserDebugMethods(services)
        RemoteViewDebugMethods(services: services).register(on: service?.router)
        services.registerMacScreenDebug(on: service?.router)
        services.registerDeviceHubDebug(on: service?.router)
        DebugNowPlaying.register(on: service?.router, services: services)
        DebugDownloads.register(on: service?.router, services: services)
        DebugCEFDevToolsLayout.register(on: service?.router, services: services)
        #if DEBUG
        // The Chromium host app prototype (browserHost.helper; cef-helper-app-DESIGN.md).
        // Socket focus policy: `open` makes the page first responder only with focus: true.
        let chromiumHost = ChromiumHostPrototype(makeConfiguration: { ChromiumHostPrototype.bundledConfiguration() },
                                                 tunables: TunableStore.shared)
        service?.router.register([
            .mainActor("debug.chromium_host") { [weak services] call in
                let controller = services?.windows.controllers.first
                let pane = (call.params["pane"]?.stringValue ?? controller?.focus.state.pane).flatMap { controller?.content?.paneController(key: $0) }
                let fields = chromiumHost.handle(op: call.params["op"]?.stringValue, url: call.params["url"]?.stringValue,
                                                 over: pane?.view.contentHost, focus: call.params["focus"]?.boolValue == true)
                return .value(JSONValue(foundation: fields) ?? .null)
            },
            .async("debug.chromium_host.measure") { call in
                guard let fields = await chromiumHost.measure(op: call.params["op"]?.stringValue, count: call.params["count"]?.intValue)
                else { return ["error": "no running Chromium host"] }
                return .object(fields.mapValues(JSONValue.number))
            }.withDeadline(.fixed(.seconds(60))),
        ])
        #endif
        DebugBrowserExternal.register(on: service?.router, services: services)
        DebugCloudMove.register(on: service?.router, services: services)
        DebugTerminalLinks.register(on: service?.router, services: services)
    }
}
