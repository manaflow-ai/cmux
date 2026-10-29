#if DEBUG
import AppKit
import CmuxNextSettings
import CmuxNextPages
import Foundation

/// `debug.devices_fixture {action?, full_access?}` (captures): Settings > Devices lists one paired client
/// machine, `leo-mbp`, from a fixture instead of `cmux device list`, and its Full access switch writes to
/// the fixture instead of acpmux `pair_set`. Actions:
/// - `show` (default): sets the fixture (`full_access`, default off) and opens Settings > Machines, whose Devices group lists it;
/// - `click`: a scripted click on the row's Full access switch, the way automation (or an agent) clicks:
///   synthesized AppKit mouse events at the switch's center, never the HID system's. The app's input
///   ledger sees them as a local monitor would, and so does the page (a real gesture to it);
/// - `state`: the fixture's Full access and the writes it took.
/// The fixture stays for the rest of the app's run, which a capture starts fresh.
@MainActor
enum DebugDevicesFixture {
    /// The fixture's Full access; nil while the fixture is off (the app reads the CLI and acpmux).
    static var fullAccess: Bool?
    /// The `pair_set` writes the fixture took, as `"<id> on|off"`.
    static var writes: [String] = []
    static let pairingID = "dv_fixture"
    static let selector = #"[data-device-full-access="paired:dv_fixture"] button[role="switch"]"#

    /// The fixture's answer to a `cmux-tui` run of the device directory; nil while the fixture is off.
    static func run(_ arguments: [String]) -> Data? {
        guard let fullAccess else { return nil }
        if arguments.starts(with: ["device", "list"]) {
            return Data("""
            {"network":{"kind":"tailscale","up":true},"devices":[
              {"id":"paired:\(pairingID)","name":"leo-mbp","kind":"computer","roles":["uses-this"],"state":"connected","full_access":\(fullAccess)}],
             "available":[],"invites":[]}
            """.utf8)
        }
        if arguments.starts(with: ["device", "audit"]) { return Data("[]".utf8) }
        return Data("{}".utf8)
    }

    /// The fixture's `pair_set`: true when it took the write; nil while the fixture is off.
    static func set(_ id: String, on: Bool) -> Bool? {
        guard fullAccess != nil else { return nil }
        writes.append("\(id) \(on ? "on" : "off")")
        fullAccess = on
        return true
    }

    static func handle(_ params: [String: JSONValue], services: AppServices?) async -> JSONValue {
        guard let services else { return .null }
        switch params["action"]?.stringValue ?? "show" {
        case "click": return await click(services)
        case "state": return state()
        default:
            fullAccess = params["full_access"]?.boolValue ?? false
            writes = []
            await services.devices.refresh()
            try? services.settingsWindow.show(section: nil, route: "#/settings/machines")
            return state()
        }
    }

    private static func state() -> JSONValue {
        .object(["full_access": fullAccess.map(JSONValue.bool) ?? .null, "writes": .array(writes.map(JSONValue.string))])
    }

    private static func click(_ services: AppServices) async -> JSONValue {
        guard let page = PageRegistry.probeTarget(id: PageDescriptor.settings.id), let window = page.window else {
            return ["error": "no Settings page in a window"]
        }
        guard !page.showsChromium else { return ["error": "Settings shows in Chromium; set browser.defaultEngine to webkit"] }
        let found = await page.debugHover(selector)
        guard found["hovered"] == true, let x = found["x"]?.doubleValue, let y = found["y"]?.doubleValue else {
            return ["error": .string("no Full access switch: \(found["error"]?.stringValue ?? "not found")")]
        }
        let webView = page.webKitView
        let scale = webView.pageZoom * webView.magnification
        let (cssX, cssY) = (CGFloat(x) * scale, CGFloat(y) * scale)
        let local = NSPoint(x: cssX, y: webView.isFlipped ? cssY : webView.bounds.height - cssY)
        let point = webView.convert(local, to: nil)
        let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard events.count == 2 else { return ["error": "could not synthesize events"] }
        let delivered: String
        if DebugNativeInput.usesAppKitPath(window) {
            DebugNativeInput.sendThroughApp(events)
            delivered = "app"
        } else {
            // A window that is not key holds a first click back from the web view: deliver it to the view,
            // after the app's input ledger records each event as its local monitor would.
            for event in events { services.personInput.record(event) }
            let app = NSApp as? CmuxApplication, outer = app?.isHandlingSendEvent() ?? false
            app?.setHandlingSendEvent(true)
            webView.mouseDown(with: events[0])
            webView.mouseUp(with: events[1])
            app?.setHandlingSendEvent(outer)
            delivered = "view"
        }
        var result: [String: JSONValue] = ["clicked": .bool(true), "delivered": .string(delivered)]
        result["ledger_person"] = services.personInput.last.map { JSONValue.bool($0.person) } ?? .null
        result["window_x"] = .number(Double(point.x))
        result["window_y"] = .number(Double(point.y))
        return .object(result)
    }
}
#endif
