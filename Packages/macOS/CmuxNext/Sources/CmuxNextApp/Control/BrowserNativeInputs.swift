import AppKit
import CmuxNextBrowser
import CmuxNextBrowserAutomation
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// Native input for `browser.page.mouse|wheel|insert_text|key` (``BrowserPageOperation/input(_:)``)
/// on a page the app shows: trusted events with the browser's default actions (Tab moves focus, a
/// held button drags, a wheel scrolls), which real sites check for.
///
/// - WebKit: AppKit events to the page's web view (``WebKitNativeInput``, the browser host
///   driver's path). The web view must be in a window.
/// - Chromium: the page's DevTools `Input.dispatchMouseEvent`, `Input.dispatchKeyEvent` and
///   `Input.insertText`, which Chromium runs as trusted input (as link hints click). The page
///   must have its browser.
///
/// Neither moves the person's pointer or keyboard focus. Without an engine view (a WebKit page in
/// no window, a page with no browser, a placeholder; for a wheel, a WebKit window on no screen,
/// decided before anything is sent) the answer is `{native: false, reason}` and
/// `BrowserPageService` runs page events instead. The buttons each page holds are kept here, so a
/// move while one is down is a drag.
@MainActor
final class BrowserNativeInputs {
    private let webKit: WebKitNativeInput
    /// The buttons a WebKit page holds, by tab key.
    private var webKitButtons: [String: MouseEventPlan] = [:]
    /// The buttons a Chromium page holds, by tab key.
    private var chromiumButtons: [String: Set<BrowserPageInput.Button>] = [:]

    /// - Parameter privateCalls: the bound on WebKit's private callbacks.
    init(privateCalls: WebKitPrivateCalls = WebKitPrivateCalls()) {
        webKit = WebKitNativeInput(privateCalls: privateCalls)
    }

    /// Delivers `input` to `page` (tab key `key`): `{native: true}`, or `{native: false, reason}`
    /// when the page has no engine view for it.
    func deliver(_ input: BrowserPageInput, to page: any BrowserTab, key: String) async throws -> JSONValue {
        if let page = page as? WebKitTab { return await webKit(input, page: page, key: key) }
        if let page = page as? CEFTab { return try await chromium(input, page: page, key: key) }
        return Self.unavailable("engine")
    }

    /// Forgets the buttons a closed tab held.
    func forget(_ key: String) {
        webKitButtons[key] = nil
        chromiumButtons[key] = nil
    }

    static func unavailable(_ reason: String) -> JSONValue { ["native": false, "reason": .string(reason)] }
    static let delivered: JSONValue = ["native": true]

    // MARK: WebKit

    private func webKit(_ input: BrowserPageInput, page: WebKitTab, key: String) async -> JSONValue {
        let webView = page.webView
        guard webView.window != nil else { return Self.unavailable("no_window") }
        do throws(WebKitNativeInput.Failure) {
            switch input {
            case let .mouse(kind, x, y, button, clickCount, modifiers):
                // AppKit has no back or forward button event: those go as page events.
                guard let plain = MouseEventPlan.Button(rawValue: button.rawValue) else { return Self.unavailable("button") }
                for step in kind == .click ? ["down", "up"] : [kind.rawValue] {
                    var plan = webKitButtons[key] ?? MouseEventPlan()
                    guard let type = plan.eventType(for: step, button: plain) else { return Self.unavailable("mouse") }
                    webKitButtons[key] = plan
                    try await webKit.mouse(type, at: CGPoint(x: x, y: y), clickCount: clickCount,
                                           flags: Self.flags(modifiers), in: webView)
                }
            case let .wheel(x, y, dx, dy, modifiers):
                // WebKit scrolls on display refresh: a window that cannot refresh would hold the
                // native wheel. Decided before sending, so the box scrolls exactly once.
                guard let window = webView.window, Self.refreshes(window) else { return Self.unavailable("no_display") }
                try await webKit.wheel(at: CGPoint(x: x, y: y), deltaX: dx, deltaY: dy, flags: Self.flags(modifiers), in: webView)
            case let .text(text):
                guard webKit.insertText(text, into: webView) else { return Self.unavailable("text") }
                await roundTrip(page)
            case let .key(name, code, _, kind, modifiers):
                let names = modifiers.map(Self.domModifier)
                guard let stroke = KeyStroke.resolve(key: name, code: code, text: nil, modifiers: names) else {
                    // No virtual key (a character no US key types): its text goes through the
                    // text input client, as the driver types it.
                    guard kind != .up, name.count == 1, webKit.insertText(name, into: webView) else { return Self.unavailable("key") }
                    await roundTrip(page)
                    return Self.delivered
                }
                if kind != .up { try webKit.key(stroke, down: true, in: webView) }
                if kind != .down { try webKit.key(stroke, down: false, upFlags: Self.flags(modifiers), in: webView) }
                await roundTrip(page)
            }
        } catch {
            return Self.unavailable(error == .noWindow ? "no_window" : "event")
        }
        return Self.delivered
    }

    /// Whether `window` can refresh its display, so WebKit runs a native wheel now: it is on a
    /// screen. An occluded window (an agent's background tab) still gets it.
    static func refreshes(_ window: NSWindow) -> Bool {
        window.screen != nil
    }

    /// One script round trip: the web process handles its messages in order, so the key or text
    /// is handled before the call answers.
    private func roundTrip(_ page: WebKitTab) async {
        _ = try? await page.evaluate("0", world: .page, gesture: .cmux)
    }

    private static func flags(_ modifiers: Set<BrowserPageInput.Modifier>) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.alt) { flags.insert(.option) }
        if modifiers.contains(.meta) { flags.insert(.command) }
        return flags
    }

    /// The DOM modifier name `KeyStroke` reads.
    private static func domModifier(_ modifier: BrowserPageInput.Modifier) -> String {
        switch modifier {
        case .shift: "Shift"
        case .control: "Control"
        case .alt: "Alt"
        case .meta: "Meta"
        }
    }

    // MARK: Chromium

    private func chromium(_ input: BrowserPageInput, page: CEFTab, key: String) async throws -> JSONValue {
        try await AppBrowserPage.ensureBrowser(page)
        // View points under a fit's or device's scale (cx-mogig), as link hints and the browser
        // host convert agent input.
        let scale = page.emulationInputScale
        do {
            switch input {
            case let .mouse(kind, x, y, button, clickCount, modifiers):
                for step in kind == .click ? [BrowserPageInput.MouseKind.down, .up] : [kind] {
                    var held = chromiumButtons[key] ?? []
                    switch step {
                    case .down: held.insert(button)
                    case .up: held.remove(button)
                    default: break
                    }
                    chromiumButtons[key] = held
                    let type = step == .down ? "mousePressed" : step == .up ? "mouseReleased" : "mouseMoved"
                    let pressed: String = step == .move ? (Self.firstHeld(held)?.rawValue ?? "none") : button.rawValue
                    _ = try await page.devTools(method: "Input.dispatchMouseEvent", params: [
                        "type": type, "x": x * scale, "y": y * scale, "button": pressed,
                        "buttons": Self.buttonMask(held), "clickCount": step == .move ? 0 : clickCount,
                        "modifiers": Self.modifierMask(modifiers),
                    ])
                }
            case let .wheel(x, y, dx, dy, modifiers):
                _ = try await page.devTools(method: "Input.dispatchMouseEvent", params: [
                    "type": "mouseWheel", "x": x * scale, "y": y * scale, "deltaX": dx, "deltaY": dy,
                    "modifiers": Self.modifierMask(modifiers),
                ])
            case let .text(text):
                _ = try await page.devTools(method: "Input.insertText", params: ["text": text])
            case let .key(name, code, keyCode, kind, modifiers):
                let mask = Self.modifierMask(modifiers)
                let typed = Self.typedText(name, modifiers: modifiers)
                if kind != .up {
                    var params: [String: any Sendable] = [
                        "type": typed == nil ? "rawKeyDown" : "keyDown", "key": name, "code": code,
                        "windowsVirtualKeyCode": keyCode, "nativeVirtualKeyCode": keyCode, "modifiers": mask,
                    ]
                    if let typed { params["text"] = typed; params["unmodifiedText"] = typed }
                    _ = try await page.devTools(method: "Input.dispatchKeyEvent", params: params)
                }
                if kind != .down {
                    _ = try await page.devTools(method: "Input.dispatchKeyEvent", params: [
                        "type": "keyUp", "key": name, "code": code, "windowsVirtualKeyCode": keyCode,
                        "nativeVirtualKeyCode": keyCode, "modifiers": mask,
                    ])
                }
            }
        } catch BrowserTabError.closed {
            return Self.unavailable("no_browser")
        }
        return Self.delivered
    }

    /// The text a key press types: one character, or Enter's carriage return; nothing with
    /// Control, Alt or Meta held.
    private static func typedText(_ key: String, modifiers: Set<BrowserPageInput.Modifier>) -> String? {
        guard modifiers.isDisjoint(with: [.control, .alt, .meta]) else { return nil }
        if key == "Enter" { return "\r" }
        return key.count == 1 ? key : nil
    }

    /// The first held button in the DOM's order.
    private static func firstHeld(_ held: Set<BrowserPageInput.Button>) -> BrowserPageInput.Button? {
        BrowserPageInput.Button.allCases.first(where: held.contains)
    }

    /// CDP `buttons`: left 1, right 2, middle 4, back 8, forward 16.
    private static func buttonMask(_ held: Set<BrowserPageInput.Button>) -> Int {
        held.reduce(0) { mask, button in mask | buttonBit(button) }
    }

    /// CDP `modifiers`: Alt 1, Control 2, Meta 4, Shift 8.
    private static func modifierMask(_ modifiers: Set<BrowserPageInput.Modifier>) -> Int {
        modifiers.reduce(0) { mask, modifier in mask | modifierBit(modifier) }
    }

    private static func buttonBit(_ button: BrowserPageInput.Button) -> Int {
        switch button {
        case .left: 1
        case .right: 2
        case .middle: 4
        case .back: 8
        case .forward: 16
        }
    }

    private static func modifierBit(_ modifier: BrowserPageInput.Modifier) -> Int {
        switch modifier {
        case .alt: 1
        case .control: 2
        case .meta: 4
        case .shift: 8
        }
    }
}
