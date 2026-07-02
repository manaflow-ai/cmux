import AppKit
import Carbon.HIToolbox
import WebKit

extension MarkdownPanel {
    @discardableResult
    func startFind() -> Bool {
        let handled = performFindAction(.showFindInterface)
        if displayMode == .preview, handled {
            setPreviewFindVisible(true)
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
        let wasVisible = isFindVisible
        let handled = performFindAction(.hideFindInterface)
        if displayMode == .preview {
            setPreviewFindVisible(false)
        }
        return handled || wasVisible
    }

    var isFindVisible: Bool {
        switch displayMode {
        case .preview:
            return isPreviewFindVisible && rendererSession.webView?.window != nil
        case .text:
            guard let textView = attachedTextViewForFind else { return false }
            return Self.textFinderBarIsVisible(for: textView) ||
                Self.isNativeFindInterfaceFocused(for: textView)
        }
    }

    var canUseSelectionForFind: Bool {
        switch displayMode {
        case .preview:
            // WKWebView exposes no *synchronous* selection API — reading the
            // current selection requires an async `evaluateJavaScript` — but
            // this property feeds synchronous menu validation for the
            // "Use Selection for Find" (Cmd+E) item. So use focus as the
            // synchronous proxy: when the preview web view is focused we defer
            // the selection decision to WebKit, which owns the selection and
            // no-ops gracefully when it is empty at Cmd+E time. This mirrors how
            // AppKit delegates selection-based edit actions to a focused web
            // view. The `.text` branch below can check the real selection only
            // because NSTextView reports `selectedRange()` synchronously.
            //
            // Focus is not an identity check: WebKit routes first responder to a
            // private content subview, not the WKWebView object itself, so a
            // focused live preview fails `firstResponder === webView`. Treat the
            // preview as focused when the WKWebView or any of its descendants
            // owns first responder — the same containment test used by
            // `isNativeFindInterfaceFocused`.
            guard let webView = rendererSession.webView,
                  let firstResponder = webView.window?.firstResponder else { return false }
            if firstResponder === webView { return true }
            return (firstResponder as? NSView)?.isDescendant(of: webView) == true
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
            if action == .hideFindInterface {
                if Self.sendCancelOperation(to: window.firstResponder ?? webView) {
                    return true
                }
                return Self.sendTextFinderAction(action, to: webView)
            }
            if action == .showFindInterface {
                window.makeFirstResponder(webView)
            }
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

    private static func sendCancelOperation(to responder: NSResponder) -> Bool {
        NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: responder, from: nil)
    }

    private static func textFinderBarIsVisible(for textView: NSTextView) -> Bool {
        guard let scrollView = textView.enclosingScrollView else { return false }
        let container = scrollView as any NSTextFinderBarContainer
        return container.isFindBarVisible
    }

    private static func isNativeFindInterfaceFocused(for owner: NSView) -> Bool {
        guard let window = owner.window,
              let firstResponder = window.firstResponder else {
            return false
        }

        if firstResponder === owner {
            return false
        }

        guard let responderView = firstResponder as? NSView else {
            return false
        }

        if responderView.isDescendant(of: owner) {
            return true
        }

        if let textView = owner as? NSTextView,
           let scrollView = textView.enclosingScrollView,
           let findBarView = (scrollView as any NSTextFinderBarContainer).findBarView {
            return responderView.isDescendant(of: findBarView)
        }

        return false
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
