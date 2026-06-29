import AppKit
import Carbon.HIToolbox
import WebKit

extension MarkdownPanel {
    @discardableResult
    func startFind() -> Bool {
        performFindAction(.showFindInterface)
    }

    @discardableResult
    func findNext() -> Bool {
        performFindAction(.nextMatch)
    }

    @discardableResult
    func findPrevious() -> Bool {
        performFindAction(.previousMatch)
    }

    private func performFindAction(_ action: NSTextFinder.Action) -> Bool {
        switch displayMode {
        case .preview:
            guard let webView = rendererSession.webView,
                  let window = webView.window else {
                return false
            }
            window.makeFirstResponder(webView)
            return Self.performWebViewFindKeyEquivalent(action, in: webView, windowNumber: window.windowNumber)
        case .text:
            guard let textView = attachedTextViewForFind else { return false }
            textView.window?.makeFirstResponder(textView)
            return Self.sendTextFinderAction(action, to: textView)
        }
    }

    private static func sendTextFinderAction(_ action: NSTextFinder.Action, to responder: NSResponder) -> Bool {
        let selector = #selector(NSResponder.performTextFinderAction(_:))
        guard responder.responds(to: selector) else { return false }
        let item = NSMenuItem(title: "", action: selector, keyEquivalent: "")
        item.tag = action.rawValue
        return NSApp.sendAction(selector, to: responder, from: item)
    }

    private static func performWebViewFindKeyEquivalent(
        _ action: NSTextFinder.Action,
        in webView: WKWebView,
        windowNumber: Int
    ) -> Bool {
        guard let event = webViewFindKeyEquivalent(action, windowNumber: windowNumber) else { return false }
        return webView.performKeyEquivalent(with: event)
    }

    private static func webViewFindKeyEquivalent(
        _ action: NSTextFinder.Action,
        windowNumber: Int
    ) -> NSEvent? {
        let key: String
        let characters: String
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags

        // WKWebView exposes its native find UI through key-equivalent handling,
        // so route the same menu chords a user would press.
        switch action {
        case .showFindInterface:
            key = "f"
            characters = "f"
            keyCode = UInt16(kVK_ANSI_F)
            modifiers = [.command]
        case .nextMatch:
            key = "g"
            characters = "g"
            keyCode = UInt16(kVK_ANSI_G)
            modifiers = [.command]
        case .previousMatch:
            key = "g"
            characters = "G"
            keyCode = UInt16(kVK_ANSI_G)
            modifiers = [.command, .shift]
        default:
            return nil
        }

        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
