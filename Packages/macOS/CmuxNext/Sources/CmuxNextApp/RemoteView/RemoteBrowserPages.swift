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
///
/// `remote.openLocalBrowserTab` (and `debug.remote_browser` `open_local`)
/// share `openLocal(url:in:)`: it starts this build's remote browser host
/// (`LocalRemoteBrowserHostLocator`) on a free loopback port, opens the tab
/// once the host listens, and stops the host when that tab closes. One host
/// serves one tab, so a page's new tab (`rb.open_tab`) starts its own host.
enum RemoteBrowserPages {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("remote.openBrowserTab", run: { invocation in
            #if DEBUG
            let address = invocation["address"]?.stringValue ?? ""
            guard let pane = context.paneController(invocation) else { return }
            try open(address: address, url: invocation["url"]?.stringValue, in: pane)
            #endif
        })
        registry.bind("remote.openLocalBrowserTab", run: { invocation in
            #if DEBUG
            guard let pane = context.paneController(invocation) else { return }
            try openLocal(url: invocation["url"]?.stringValue.flatMap(URL.init(string:)), in: pane)
            #endif
        })
    }

    #if DEBUG
    /// Live sessions by tab key, for the debug socket (weak: tabs own them).
    @MainActor private static var sessions: [String: WeakSession] = [:]

    private struct WeakSession {
        weak var value: RemoteBrowserSession?
    }

    /// Hosts this app started, by port, each owned until its tab closes.
    @MainActor private static var localHosts: [UInt16: LocalRemoteBrowserHost] = [:]
    /// Hosts still starting, and the last start failure (debug socket).
    @MainActor private static var startingLocalHosts = 0
    @MainActor private static var lastLocalFailure: String?

    /// The first page of a local remote tab opened without a URL.
    static let localStartPage = URL(string: "https://www.google.com/")

    /// Starts a local host for `url` (nil: `localStartPage`) and
    /// opens its tab in `pane` once it listens; `then` gets the new tab's
    /// surface id. Throws at once when this
    /// build has no host; a host that fails to start shows an alert.
    @MainActor
    static func openLocal(url: URL?, in pane: PaneController, background: Bool = false,
                          then: (@MainActor (String) -> Void)? = nil) throws {
        guard let executable = LocalRemoteBrowserHostLocator().executable() else {
            throw ActionFailure(message: RemoteBrowserStrings.hostNotInBuild(LocalRemoteBrowserHostLocator.environmentKey))
        }
        let page = (url ?? localStartPage).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        startingLocalHosts += 1
        // task-owner: one host start; ends when the host listens or exits. The host then belongs to localHosts until its tab closes.
        Task { [weak pane] in
            defer { startingLocalHosts -= 1 }
            do {
                let host = try await LocalRemoteBrowserHost.start(executable: executable, pageURL: page)
                let record = RemoteBrowserTabRecord(endpoint: host.endpoint)
                localHosts[host.endpoint.port] = host
                guard let pane, pane.newBrowserTab(url: record.url, background: background, then: { surface in
                    then?(String(describing: surface))
                }) else {
                    localHosts[host.endpoint.port] = nil
                    host.stop()
                    return
                }
            } catch {
                lastLocalFailure = String(describing: error)
                guard let window = pane?.view.window else { return }
                let alert = NSAlert()
                alert.messageText = RemoteBrowserStrings.hostDidNotStart
                alert.informativeText = String(describing: error)
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
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
        let localHost = localHosts[record.endpoint.port]
        session.openTab = { [weak services] target, disposition, answer in
            // A page's new tab is a remote tab on the same runtime host (RT1).
            guard let services, let holder = pane(holding: key, services: services) else { return answer(nil) }
            let background = disposition == .backgroundTab
            guard localHost == nil else {
                // A local host serves one tab: the new tab gets its own host.
                do {
                    try openLocal(url: target, in: holder, background: background) { answer($0) }
                } catch {
                    answer(nil)
                }
                return
            }
            let child = RemoteBrowserTabRecord(endpoint: record.endpoint, initialURL: target)
            holder.newBrowserTab(url: child.url, background: background) { surface in
                answer(String(describing: surface))
            }
        }
        if let localHost {
            let port = record.endpoint.port
            // The tab owns its host: closing the tab stops it.
            session.onClose = { [weak localHost] in
                localHost?.stop()
                if localHosts[port] === localHost { localHosts[port] = nil }
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
    /// runs the shared open path in that pane or the focused one; `open_local`
    /// (`url`?, `pane`?) runs `openLocal`; `state` (default) lists live
    /// sessions; `navigate` (`url`, `tab`?) loads a page the way the omnibar
    /// does (`BrowserTab.load`); `history` (`op`) goes back, forward,
    /// reloads or stops as the toolbar does; `scroll` (`x`, `y`, `dy`, `dx`) and `move`
    /// (`x`, `y`) send a wheel or hover event; `menu_choose` (`id` or `index`, `tab`?)
    /// answers the open native menu; `menu_cancel` dismisses it; `click`
    /// (`x`, `y`, `button`, `modifiers`) clicks the page.
    @MainActor
    static func debug(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let live = sessions.compactMapValues(\.value)
        let target = params["tab"]?.stringValue.flatMap { live[$0] } ?? live.values.first
        switch params["action"]?.stringValue ?? "state" {
        case "open", "open_local":
            // A background app has no active window: `pane` names one, else
            // the active window's focused pane, else the first window's.
            let named = params["pane"]?.stringValue.flatMap { key in
                services.windows.controllers.lazy.compactMap { $0.content?.panes.values.first { $0.paneKey == key } }.first
            }
            guard let pane = named ?? services.windows.active?.focusedPane ?? services.windows.controllers.first?.focusedPane else {
                return ["error": "no pane"]
            }
            do {
                if params["action"]?.stringValue == "open_local" {
                    try openLocal(url: params["url"]?.stringValue.flatMap(URL.init(string:)), in: pane)
                    return ["starting": true]
                }
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
                    "cursor": session.nativeUI.cursorKind.map(JSONValue.string) ?? .null,
                    "surfaces": .array(session.surfaces.surfaceIDs.map { .number(Double($0)) }),
                    "frame": .string("\(Int(session.pane.view.frame.width))x\(Int(session.pane.view.frame.height))"),
                ])
            }
            var hosts: [JSONValue] = []
            for (port, host) in localHosts.sorted(by: { $0.key < $1.key }) {
                let row: [String: JSONValue] = [
                    "port": .number(Double(port)), "pid": .number(Double(host.processIdentifier)), "log": .string(host.logURL.path),
                ]
                hosts.append(.object(row))
            }
            let failure: JSONValue = lastLocalFailure.map(JSONValue.string) ?? .null
            return ["sessions": .array(rows), "local_hosts": .array(hosts),
                    "local_starting": .number(Double(startingLocalHosts)), "local_failure": failure]
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
        case "history":
            // `op`: `back`, `forward`, `reload` or `stop`, as the toolbar does.
            guard let tab = target?.tab else { return ["error": "no session"] }
            switch params["op"]?.stringValue {
            case "back": tab.goBack()
            case "forward": tab.goForward()
            case "reload": tab.reload()
            case "stop": tab.stop()
            default: return ["error": "op is back, forward, reload or stop"]
            }
            return ["sent": true]
        case "scroll", "move":
            // `scroll`: a pixel wheel event of `dy` (and `dx`) at `x`,`y`;
            // `move`: the pointer moves to `x`,`y` (hover). Page CSS pixels
            // from the top left, through the page view's own pointer path.
            guard let tab = target?.tab else { return ["error": "no session"] }
            let view = tab.pane.view
            guard let window = view.window else { return ["error": "the tab is not in a window"] }
            let point = view.convert(NSPoint(x: params["x"]?.doubleValue ?? 10, y: params["y"]?.doubleValue ?? 10), to: nil)
            let scroll = params["action"]?.stringValue == "scroll"
            let event: NSEvent?
            if scroll {
                // A wheel NSEvent comes only from a CGEvent: global top-left
                // coordinates, aimed at this window.
                let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(params["dy"]?.doubleValue ?? 0), wheel2: Int32(params["dx"]?.doubleValue ?? 0), wheel3: 0)
                let screen = window.convertPoint(toScreen: point)
                cgEvent?.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
                cgEvent?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                cgEvent?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                event = cgEvent.flatMap { NSEvent(cgEvent: $0) }
            } else {
                event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
            }
            guard let event else { return ["error": "no event"] }
            tab.handlePointer(event)
            return [scroll ? "scrolled" : "moved": true]
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
