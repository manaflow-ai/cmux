import AppKit
import Carbon.HIToolbox
import WebKit

extension MarkdownPanel {
    @discardableResult
    func startFind() -> Bool {
        let handled = performFindAction(.showFindInterface)
        if handled {
            isFindVisible = true
        }
        return handled
    }

    @discardableResult
    func findNext() -> Bool {
        performFindAction(.nextMatch)
    }

    @discardableResult
    func findPrevious() -> Bool {
        performFindAction(.previousMatch)
    }

    @discardableResult
    func hideFind() -> Bool {
        let handled = performFindAction(.hideFindInterface)
        if handled || isFindVisible {
            isFindVisible = false
            return true
        }
        return false
    }

    var canUseSelectionForFind: Bool {
        switch displayMode {
        case .preview:
            guard let webView = rendererSession.webView else { return false }
            return webView.window?.firstResponder === webView
        case .text:
            guard let textView = attachedTextViewForFind else { return false }
            return textView.selectedRange().length > 0
        }
    }

    @discardableResult
    func searchSelection() -> Bool {
        switch displayMode {
        case .preview:
            guard let webView = rendererSession.webView,
                  let window = webView.window else {
                return false
            }
            window.makeFirstResponder(webView)
            let handled = Self.performWebViewFindKeyEquivalent(
                .setSearchString,
                in: webView,
                windowNumber: window.windowNumber
            )
            return handled
        case .text:
            guard let textView = attachedTextViewForFind,
                  textView.selectedRange().length > 0 else {
                return false
            }
            textView.window?.makeFirstResponder(textView)
            let setSearchString = Self.sendTextFinderAction(.setSearchString, to: textView)
            let showFind = Self.sendTextFinderAction(.showFindInterface, to: textView)
            if setSearchString || showFind {
                isFindVisible = true
            }
            return setSearchString || showFind
        }
    }

    private func performFindAction(_ action: NSTextFinder.Action) -> Bool {
        switch displayMode {
        case .preview:
            guard let webView = rendererSession.webView,
                  let window = webView.window else {
                return false
            }
            window.makeFirstResponder(webView)
            if Self.performWebViewFindKeyEquivalent(action, in: webView, windowNumber: window.windowNumber) {
                return true
            }
            return Self.sendTextFinderAction(action, to: webView)
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
        case .setSearchString:
            key = "e"
            characters = "e"
            keyCode = UInt16(kVK_ANSI_E)
            modifiers = [.command]
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
