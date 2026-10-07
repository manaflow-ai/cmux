import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings
import Foundation
#if DEBUG
import CmuxNextRemoteBrowser
#endif

/// Development remote tabs (remote-tab.md r2): `remote.openBrowserTab`
/// (palette, and scripts through `action.run`) and the `debug.remote_browser`
/// socket verb share `open(address:url:in:)`, which opens a browser record
/// `cmux://remote-browser?address=…`; `TabContentCache` turns that record
/// into a `RemoteBrowserTab` streamed from the loopback rb/1 host.
enum RemoteBrowserPages {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("remote.openBrowserTab", run: { invocation in
            #if DEBUG
            let address = invocation["address"]?.stringValue ?? ""
            guard let pane = context.paneController(invocation) else { return }
            try open(address: address, url: invocation["url"]?.stringValue, in: pane)
            #endif
        })
    }

    #if DEBUG
    /// Live sessions by tab key, for the debug socket (weak: tabs own them).
    @MainActor private static var sessions: [String: WeakSession] = [:]

    private struct WeakSession {
        weak var value: RemoteBrowserSession?
    }

    /// The one open path: refuses anything but a loopback host port.
    @MainActor
    static func open(address: String, url: String?, in pane: PaneController) throws {
        let first = url.flatMap(URL.init(string:))
        guard let record = RemoteBrowserTabRecord(address: address, initialURL: first) else {
            throw ActionFailure(message: RemoteBrowserStrings.addressNotRecognized(address))
        }
        pane.newBrowserTab(url: record.url)
    }

    /// The native page of a `cmux://remote-browser` record (nil for a bad
    /// address: the history fallback is not used for these records).
    @MainActor
    static func makePage(url: URL, key: String, profile: BrowserProfileID, services: AppServices) -> (any BrowserTab)? {
        guard let record = RemoteBrowserTabRecord(url: url),
              let tab = RemoteBrowserSession.makeTab(record: record, id: BrowserTabID(rawValue: key), profile: profile,
                                                     viewer: "cmux-next"),
              let session = RemoteBrowserSession.session(of: tab) else { return nil }
        session.openTab = { [weak services] target, disposition, answer in
            // A page's new tab is a remote tab on the same host (RT1).
            guard let services, let holder = pane(holding: key, services: services) else { return answer(nil) }
            let child = RemoteBrowserTabRecord(endpoint: record.endpoint, initialURL: target)
            holder.newBrowserTab(url: child.url, background: disposition == .backgroundTab) { surface in
                answer(String(describing: surface))
            }
        }
        sessions = sessions.filter { $0.value.value != nil }
        sessions[key] = WeakSession(value: session)
        session.start()
        return tab
    }

    @MainActor
    private static func pane(holding key: String, services: AppServices) -> PaneController? {
        for window in services.windows.controllers {
            for pane in window.content?.panes.values.map({ $0 }) ?? [] where pane.pane.tabs.contains(where: { $0.id == key }) {
                return pane
            }
        }
        return nil
    }

    /// `debug.remote_browser`. Actions: `open` (`address`, `url`?, `pane`?)
    /// runs the shared open path in that pane or the focused one; `state` (default) lists live
    /// sessions; `navigate` (`url`, `tab`?) loads a page the way the omnibar
    /// does (`BrowserTab.load`); `menu_choose` (`id` or `index`, `tab`?)
    /// answers the open native menu; `menu_cancel` dismisses it; `click`
    /// (`x`, `y`, `button`, `modifiers`) clicks the page.
    @MainActor
    static func debug(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let live = sessions.compactMapValues(\.value)
        let target = params["tab"]?.stringValue.flatMap { live[$0] } ?? live.values.first
        switch params["action"]?.stringValue ?? "state" {
        case "open":
            // A background app has no active window: `pane` names one, else
            // the active window's focused pane, else the first window's.
            let named = params["pane"]?.stringValue.flatMap { key in
                services.windows.controllers.lazy.compactMap { $0.content?.panes.values.first { $0.paneKey == key } }.first
            }
            guard let pane = named ?? services.windows.active?.focusedPane ?? services.windows.controllers.first?.focusedPane else {
                return ["error": "no pane"]
            }
            do {
                try open(address: params["address"]?.stringValue ?? "", url: params["url"]?.stringValue, in: pane)
                return ["opened": true]
            } catch {
                return ["error": .string(String(describing: error))]
            }
        case "state":
            let rows: [JSONValue] = live.sorted { $0.key < $1.key }.map { key, session in
                .object([
                    "tab": .string(key),
                    "url": session.tab?.state.url.map { .string($0.absoluteString) } ?? .null,
                    "title": session.tab?.state.title.map(JSONValue.string) ?? .null,
                    "menu": session.nativeUI.openMenuTitles.map { .array($0.map(JSONValue.string)) } ?? .null,
                    "dialog": session.nativeUI.openDialogToken.map { .number(Double($0)) } ?? .null,
                    "note": session.lastNote.map(JSONValue.string) ?? .null,
                    "frame": .string("\(Int(session.pane.view.frame.width))x\(Int(session.pane.view.frame.height))"),
                ])
            }
            return ["sessions": .array(rows)]
        case "navigate":
            guard let target, let url = params["url"]?.stringValue.flatMap(URL.init(string:)) else { return ["error": "tab and url are required"] }
            target.tab?.load(url)
            return ["navigated": true]
        case "click":
            // A click at `x`,`y` (page CSS pixels from the top left) with
            // `button` (`left`, `right`) and `modifiers` (`cmd`, `shift`,
            // `option`, `ctrl`), through the page view's own pointer path.
            guard let tab = target?.tab else { return ["error": "no session"] }
            let view = tab.pane.view
            guard let window = view.window else { return ["error": "the tab is not in a window"] }
            let point = view.convert(NSPoint(x: params["x"]?.doubleValue ?? 10, y: params["y"]?.doubleValue ?? 10), to: nil)
            var flags: NSEvent.ModifierFlags = []
            for name in params["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                switch name {
                case "cmd", "command": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "option", "alt": flags.insert(.option)
                case "ctrl", "control": flags.insert(.control)
                default: break
                }
            }
            let right = params["button"]?.stringValue == "right"
            let types: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
            for type in types {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                tab.handlePointer(event)
            }
            return ["clicked": true]
        case "menu_choose":
            guard let target else { return ["error": "no session"] }
            if let id = params["id"]?.intValue { return ["chosen": .bool(target.nativeUI.choose(.command(Int64(id))))] }
            if let index = params["index"]?.intValue { return ["chosen": .bool(target.nativeUI.choose(.indices([UInt32(clamping: index)])))] }
            return ["error": "id or index is required"]
        case "menu_cancel":
            guard let target else { return ["error": "no session"] }
            return ["chosen": .bool(target.nativeUI.choose(.cancel))]
        default:
            return ["error": "unknown action"]
        }
    }
    #endif
}

extension AppControl {
    func registerRemoteBrowserDebugMethods(_ services: AppServices) {
        #if DEBUG
        service?.router.register([
            .mainActor("debug.remote_browser") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(RemoteBrowserPages.debug(call.params, services: services))
            },
        ])
        #endif
    }
}
