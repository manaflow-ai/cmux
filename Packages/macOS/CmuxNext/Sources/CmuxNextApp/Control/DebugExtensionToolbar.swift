import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextSettings

#if DEBUG
/// Debug-build control methods that drive the extension toolbar without a
/// pointer (the extension e2e suite and agent verification). Each acts on
/// the browser chrome of `tab` (a tab id) or of the focused pane.
///
/// - `debug.extensions.toolbar`: layout report (frames, visible and
///   overflowed actions, Forward, open popup and its anchor).
/// - `debug.extensions.click {extension}`: clicks the extension's toolbar
///   button, or runs it from the Extensions menu when it has no button;
///   `{button: "extensions"}` opens the Extensions menu;
///   `{extension, menu: true}` opens the extension's menu (right click).
/// - `debug.extensions.menu`: the open Extensions or extension menu's items;
///   `{choose: <operation>, extension}` does what that row control does
///   (`run`, `pin`, `unpin`, `more`) or chooses a footer item
///   (`manage`, `webStore`, `loadUnpacked`) or an extension menu item by
///   operation; `{dismiss: true}` closes it.
/// - `debug.extensions.popup {hide: true}`: closes the open action popup.
@MainActor
enum DebugExtensionToolbar {
    static func chrome(_ params: [String: JSONValue], _ services: AppServices) -> BrowserChromeView? {
        let target = params["tab"]?.stringValue.map { ActionTargetRef(kind: .tab, id: $0) }
        guard case .browser(let entry)? = ActionScope(services: services, invocation: ActionInvocation(target: target))
            .pane?.currentContent else { return nil }
        return entry.chrome
    }

    static func toolbar(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        guard let chrome = chrome(params, services) else { return failure("no browser chrome") }
        let report = chrome.toolbarReport
        var object: [String: JSONValue] = [
            "width": .number(Double(report.width)), "shows_forward": .bool(report.showsForward),
            "shows_extensions_button": .bool(report.showsExtensionsButton),
            "visible_actions": .array(report.visibleActions.map { .string($0) }),
            "overflow_actions": .array(report.overflowActions.map { .string($0) }),
            "frames": .object(report.frames.mapValues(rect)), "toolbar": rect(report.toolbarBounds),
            "fits": .bool(report.fits), "menu_open": .bool(chrome.presentedExtensionsMenu != nil),
        ]
        if let popup = report.openPopup { object["open_popup"] = .string(popup) }
        if let anchor = report.popupAnchor { object["popup_anchor"] = rect(anchor) }
        return .object(object)
    }

    static func click(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        guard let chrome = chrome(params, services) else { return failure("no browser chrome") }
        if params["button"]?.stringValue == "extensions" {
            chrome.presentExtensionsMenu()
            return .object(["ok": .bool(true)])
        }
        guard let id = params["extension"]?.stringValue else { return failure("extension or button required") }
        if params["menu"]?.boolValue == true {
            chrome.presentExtensionsMenu(for: id)
        } else {
            chrome.runExtensionAction(id)
        }
        return .object(["ok": .bool(true), "anchored_to": .string(chrome.toolbarReport.visibleActions.contains(id) ? "action" : "extensions")])
    }

    static func menu(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        guard let chrome = chrome(params, services) else { return failure("no browser chrome") }
        guard let menu = chrome.presentedExtensionsMenu else { return .object(["open": .bool(false)]) }
        let items: [JSONValue] = menu.items.map { item in
            if item.isSeparatorItem { return .string("-") }
            var object: [String: JSONValue] = ["title": .string(item.title), "enabled": .bool(item.isEnabled)]
            if let id = item.identifier?.rawValue { object["identifier"] = .string(id) }
            if let extensionID = item.representedObject as? String { object["extension"] = .string(extensionID) }
            return .object(object)
        }
        if params["dismiss"]?.boolValue == true {
            menu.cancelTracking()
            return .object(["open": .bool(true), "items": .array(items), "dismissed": .bool(true)])
        }
        guard let choose = params["choose"]?.stringValue else { return .object(["open": .bool(true), "items": .array(items)]) }
        let extensionID = params["extension"]?.stringValue
        guard ExtensionMenuDriver.choose(choose, extension: extensionID, in: menu) else {
            return failure("no \(choose) item\(extensionID.map { " for \($0)" } ?? "")")
        }
        return .object(["open": .bool(true), "items": .array(items), "chose": .string(choose)])
    }

    /// `{extension, to}`: moves a pinned button to index `to`, as the
    /// toolbar drag does when released there.
    static func drag(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        guard let chrome = chrome(params, services) else { return failure("no browser chrome") }
        guard let id = params["extension"]?.stringValue, let to = params["to"]?.intValue else { return failure("extension and to required") }
        return .object(["ok": .bool(chrome.moveExtensionAction(id, to: to))])
    }

    static func popup(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        guard let chrome = chrome(params, services),
              let host = chrome.tab as? any BrowserExtensionActionHosting else { return failure("no Chromium tab") }
        if params["hide"]?.boolValue == true { host.hideExtensionPopups() }
        return .object(["open_popup": host.openExtensionPopup.map { .string($0) } ?? .null])
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        .object(["x": .number(Double(rect.minX)), "y": .number(Double(rect.minY)),
                 "w": .number(Double(rect.width)), "h": .number(Double(rect.height))])
    }

    private static func failure(_ message: String) -> JSONValue { .object(["error": .string(message)]) }
}

#endif
