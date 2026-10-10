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
            try open(address: address, url: invocation["url"]?.stringValue, secretFile: invocation["secretFile"]?.stringValue, in: pane)
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
                alert.informativeText = RemoteBrowserStrings.hostFailure(error)
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// The one open path: refuses anything but a loopback host port, and a
    /// `secretFile` that is not a private file with a secret (the host
    /// serves only a viewer with its per-launch secret). The record keeps
    /// the file's path; the secret is read when the tab connects.
    @MainActor
    static func open(address: String, url: String?, secretFile: String? = nil, machine: String? = nil, in pane: PaneController) throws {
        let first = url.flatMap(URL.init(string:))
        guard let record = RemoteBrowserTabRecord(address: address, initialURL: first, secretFile: secretFile, machine: machine) else {
            throw ActionFailure(message: RemoteBrowserStrings.addressNotRecognized(address))
        }
        if let path = record.secretFile {
            do {
                _ = try RemoteBrowserSecretFile(path: path).read()
            } catch {
                throw ActionFailure(message: RemoteBrowserStrings.secretFile(error, path: path))
            }
        }
        pane.newBrowserTab(url: record.url)
    }

    /// The hello token of a tab: the secret of the host this app started on
    /// that port, else the record's secret file; a file that cannot be used
    /// is the tab's failure (it then does not connect).
    @MainActor
    private static func hostToken(for record: RemoteBrowserTabRecord) -> Result<String?, RemoteBrowserFailure> {
        if record.machine == nil, let secret = localHosts[record.endpoint.port]?.secret { return .success(secret) }
        guard let path = record.secretFile else { return .success(nil) }
        do {
            return .success(try RemoteBrowserSecretFile(path: path).read())
        } catch {
            return .failure(.secretFile(error, path: path))
        }
    }

    /// The native page of a `cmux://remote-browser` record (nil for a bad
    /// address: the history fallback is not used for these records).
    @MainActor
    static func makePage(url: URL, key: String, profile: BrowserProfileID, services: AppServices) -> (any BrowserTab)? {
        // A host serves only the viewer with its secret: a host this app
        // started gives it, else the record's secret file.
        guard let record = RemoteBrowserTabRecord(url: url) else { return nil }
        let credential = hostToken(for: record)
        // A host on another machine: its loopback over the machine's daemon link.
        let carrier = record.machine.map { services.remoteLocalhost.browserCarrier(machine: $0, port: record.endpoint.port) }
        guard let tab = RemoteBrowserSession.makeTab(record: record, id: BrowserTabID(rawValue: key), profile: profile,
                                                     viewer: "cmux-next", token: try? credential.get(), carrier: carrier),
              let session = RemoteBrowserSession.session(of: tab) else { return nil }
        let localHost = record.machine == nil ? localHosts[record.endpoint.port] : nil
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
            let child = RemoteBrowserTabRecord(endpoint: record.endpoint, initialURL: target, secretFile: record.secretFile, machine: record.machine)
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
        if case let .failure(failure) = credential {
            session.fail(failure)
        } else {
            session.start()
        }
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

    /// `debug.remote_browser`. Actions: `open` (`address`, `url`?, `secret_file`?, `machine`?, `pane`?)
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
                try open(address: params["address"]?.stringValue ?? "", url: params["url"]?.stringValue,
                         secretFile: params["secret_file"]?.stringValue, machine: params["machine"]?.stringValue, in: pane)
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
                    "failure": session.tab?.pane.view.failureMessage.map(JSONValue.string) ?? .null,
                    "cursor": session.nativeUI.cursorKind.map(JSONValue.string) ?? .null,
                    "surfaces": .array(session.surfaces.surfaceIDs.map { .number(Double($0)) }),
                    // `frame`: the anchor in page CSS pixels; `panel`: the
                    // surface's child panel (window number, screen frame
                    // x,y w x h from the bottom left, parent window number,
                    // shown, key).
                    "surface_info": .array(session.surfaces.surfaceIDs.map { id in
                        let frame = session.surfaces.anchor(of: id) ?? .zero
                        let panel: JSONValue = session.surfaces.panel(of: id).map { panel -> JSONValue in
                            let f = panel.frame
                            return .object([
                                "window_number": .number(Double(panel.windowNumber)),
                                "screen_frame": .string("\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"),
                                "parent": panel.parent.map { JSONValue.number(Double($0.windowNumber)) } ?? .null,
                                "visible": .bool(panel.isVisible), "key": .bool(panel.isKeyWindow),
                            ])
                        } ?? .null
                        return .object([
                            "id": .number(Double(id)), "kind": session.surfaces.kind(of: id).map(JSONValue.string) ?? .null,
                            "frame": .string("\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"),
                            "panel": panel,
                        ])
                    }),
                    "page_screen_frame": session.pane.view.window.map { window -> JSONValue in
                        let f = window.convertToScreen(session.pane.view.convert(session.pane.view.bounds, to: nil))
                        return .string("\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
                    } ?? .null,
                    "key_window": NSApp.keyWindow.map { JSONValue.number(Double($0.windowNumber)) } ?? .null,
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
        case "surface_click":
            // A left click at `x`,`y` (the surface's CSS pixels from its top
            // left) on open popup surface `surface`, sent to the surface's
            // panel as AppKit delivers a click (hit test, first mouse in a
            // panel that is never key, the view's pointer path).
            guard let target, let id = params["surface"]?.intValue,
                  let view = target.surfaces.view(of: UInt32(clamping: id)) else { return ["error": "no such surface"] }
            guard let window = view.window else { return ["error": "the surface is not in a window"] }
            let point = view.convert(NSPoint(x: params["x"]?.doubleValue ?? 10, y: params["y"]?.doubleValue ?? 10), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                window.sendEvent(event)
            }
            return ["clicked": true]
        case "type":
            // Types `text` (lowercase a-z) on the page's key path, a key down
            // and up per letter, as the keyboard would.
            guard let tab = target?.tab, let window = tab.pane.view.window else { return ["error": "no session"] }
            let codes: [Character: UInt16] = [
                "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
                "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            ]
            let text = params["text"]?.stringValue ?? ""
            guard text.allSatisfy({ codes[$0] != nil }) else { return ["error": "text is lowercase a-z"] }
            for character in text {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: String(character),
                        charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: codes[character] ?? 0) else { continue }
                    tab.handleKey(event)
                }
            }
            return ["typed": .number(Double(text.count))]
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
