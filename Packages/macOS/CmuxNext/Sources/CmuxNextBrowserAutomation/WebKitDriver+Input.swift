import AppKit
import CmuxNextBrowser
import Foundation
import WebKit

/// Native input: AppKit events handed to the tab's web view, so the page
/// sees trusted events (`isTrusted === true`). Nothing is posted to the
/// system event stream; the user's pointer and keyboard focus never move.
/// The events come from ``WebKitNativeInput``, shared with the App's
/// `browser.page.*` input.
extension WebKitDriver {
    private var native: WebKitNativeInput { WebKitNativeInput(privateCalls: privateCalls) }

    func inputMouse(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try target(params)
        let webView = tab.webView
        guard webView.window != nil else { throw Self.noWindow }
        let type = try params.string("type")
        let css = CGPoint(x: try params.number("x"), y: try params.number("y"))
        let flags = KeyStroke.flags(named: try params.strings("modifiers"))
        if type == "wheel" {
            let dx = try params.optionalNumber("deltaX") ?? 0
            let dy = try params.optionalNumber("deltaY") ?? 0
            do {
                try await native.wheel(at: css, deltaX: dx, deltaY: dy, flags: flags, in: webView)
            } catch {
                throw Self.inputError(error, "input.mouse: could not create a wheel event")
            }
            return .null
        }
        // A right-click's native menu is not shown (`agentRightMouseDown`).
        let button = MouseEventPlan.Button(rawValue: try params.optionalString("button") ?? "left") ?? .left
        guard let eventType = session.mouse.eventType(for: type, button: button) else {
            throw DriverError(.invalid, "input.mouse: type: expected move, down, up or wheel, got \(type)")
        }
        session.mouseLocation = css
        let clickCount = Int(exactly: (try params.optionalNumber("clickCount") ?? 1).rounded()) ?? 1
        do {
            try await native.mouse(eventType, at: css, clickCount: clickCount, flags: flags, in: webView)
        } catch {
            throw Self.inputError(error, "input.mouse: could not create a mouse event")
        }
        return .null
    }

    /// `nativeCommand: false` (a clipboard shortcut, WebKitClipboard):
    /// the page gets the key, but its editing command (`paste:`, which reads
    /// the system pasteboard) does not run.
    func inputKey(_ params: DriverParams, nativeCommand: Bool = true) async throws(DriverError) -> DriverJSON {
        let (tab, _) = try target(params)
        let webView = tab.webView
        let type = try params.string("type")
        let key = try params.string("key")
        let text = try params.optionalString("text")
        let modifiers = try params.strings("modifiers")
        guard let stroke = KeyStroke.resolve(key: key, code: try params.optionalString("code") ?? "", text: text,
                                             modifiers: modifiers) else {
            // No virtual key: the text goes through the text input client.
            if type == "down", let text, !text.isEmpty { native.insertText(text, into: webView) }
            return .null
        }
        do {
            try native.key(stroke, down: type == "down", isARepeat: try params.bool("autoRepeat"),
                           upFlags: KeyStroke.flags(named: modifiers), nativeCommand: nativeCommand, in: webView)
        } catch {
            throw DriverError(.invalid, "input.key: could not create a key event for \(key)")
        }
        // A script round trip after the key: the web process handles its
        // messages in order, so the key is handled before this returns, and
        // text the next call inserts (an emoji, IME text) cannot pass it.
        if let tab = try? target(params).0 { _ = try? await run("return 0;", [:], nil, AgentWorld.hostWorld, tab) }
        return .null
    }

    /// An IME-style commit into the focused element. Rich-text editors that
    /// start an edit only on a composition get marked text first (UNVERIFIED
    /// here; #15570 does it after a presentation update).
    func inputInsertText(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, _) = try target(params)
        let text = try params.string("text")
        guard native.insertText(text, into: tab.webView) else {
            throw DriverError(.unsupported, "input.insertText: the web view takes no text input")
        }
        return .null
    }

    private static var noWindow: DriverError {
        DriverError(.unsupported, "input.mouse: the tab is not in a window (hidden tabs need the off-screen render window)")
    }

    private static func inputError(_ failure: WebKitNativeInput.Failure, _ message: String) -> DriverError {
        switch failure {
        case .noWindow: noWindow
        case .noEvent: DriverError(.invalid, message)
        }
    }
}
