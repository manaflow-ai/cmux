import AppKit
import Bonsplit
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Keyboard command routing and paste-as-plain-text commands
extension CmuxWebView {
    private static let pasteAsPlainTextKeyCode: UInt16 = 9 // V key (hardware position, layout-independent)
    private static func isPasteAsPlainTextCommandEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
        return event.keyCode == pasteAsPlainTextKeyCode && normalizedFlags == [.command, .shift]
    }

    private func webKitPasteAsPlainTextFallback(_ sender: Any?) {
        let selector = NSSelectorFromString("pasteAsPlainText:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else {
            return
        }

        typealias PasteAsPlainTextFn = @convention(c) (AnyObject, Selector, Any?) -> Void
        let implementation = method_getImplementation(method)
        unsafeBitCast(implementation, to: PasteAsPlainTextFn.self)(self, selector, sender)
    }

    // Key-equivalent handling is synchronous, so this bounded preflight pumps the main run loop.
    // Keep callers limited to fast, side-effect-free reads from page-owned state.
    private func evaluateJavaScriptSynchronously(
        _ script: String,
        timeout: TimeInterval = 0.25
    ) -> (completed: Bool, result: Any?, error: Error?) {
        var completed = false
        var result: Any?
        var error: Error?

        evaluateJavaScript(script) { jsResult, jsError in
            result = jsResult
            error = jsError
            completed = true
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !completed {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }

            let sliceEnd = Date(timeIntervalSinceNow: min(remaining, 0.01))
            _ = RunLoop.current.run(mode: .default, before: sliceEnd)
            if !completed {
                _ = RunLoop.current.run(mode: .eventTracking, before: sliceEnd)
            }
        }

        return (completed, result, error)
    }

    private func pageCanAcceptPlainTextPaste() -> Bool {
        let script = """
        (() => {
            try {
                const fn = window.__cmuxCanPasteAsPlainTextIntoCurrentFocus;
                return typeof fn === 'function' ? !!fn() : false;
            } catch (_) {
                return false;
            }
        })();
        """

        let evaluation = evaluateJavaScriptSynchronously(script)
        let canPaste = evaluation.completed && ((evaluation.result as? Bool) ?? false)
#if DEBUG
        let errorDescription = evaluation.completed
            ? (evaluation.error?.localizedDescription ?? "nil")
            : "timeout"
        cmuxDebugLog(
            "browser.pasteAsPlainText.preflight " +
            "web=\(ObjectIdentifier(self)) canPaste=\(canPaste ? 1 : 0) " +
            "error=\(errorDescription)"
        )
#endif
        return canPaste
    }

    private func shouldSkipRepeatedPasteAsPlainTextPreflight(for event: NSEvent) -> Bool {
        guard event.timestamp > 0,
              let lastTimestamp = lastPasteAsPlainTextPerformKeyEventTimestamp else {
            return false
        }
        lastPasteAsPlainTextPerformKeyEventTimestamp = nil
        return lastTimestamp == event.timestamp
    }

    @discardableResult
    private func performPasteAsPlainTextFromPasteboard(_ sender: Any? = nil) -> Bool {
        guard pasteAsPlainTextTargetAvailable,
              NSPasteboard.general.string(forType: .string) != nil,
              pageCanAcceptPlainTextPaste() else {
            return false
        }

        webKitPasteAsPlainTextFallback(sender)
#if DEBUG
        cmuxDebugLog(
            "browser.pasteAsPlainText " +
            "web=\(ObjectIdentifier(self)) routedNative=1"
        )
#endif
        return true
    }

    @IBAction func pasteAsPlainText(_ sender: Any?) {
        _ = sender
        if !performPasteAsPlainTextFromPasteboard(sender) {
            webKitPasteAsPlainTextFallback(sender)
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(pasteAsPlainText(_:)) {
            return pasteAsPlainTextTargetAvailable
                && NSPasteboard.general.string(forType: .string) != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        var handled = false
        defer {
            CmuxTypingTiming.logDuration(
                path: "browser.web.performKeyEquivalent",
                startedAt: typingTimingStart,
                event: event,
                extra: "handled=\(handled ? 1 : 0)"
            )
        }
        func finish(_ result: Bool) -> Bool {
            handled = result
            return result
        }
#else
        func finish(_ result: Bool) -> Bool { result }
#endif
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
        if let decision = AppDelegate.shared?.handleBrowserFocusModeKeyEvent(
            event,
            webView: self,
            source: "web.performKeyEquivalent"
        ), decision != .inactive {
            switch decision {
            case .inactive:
                break
            case .forwardToWebView:
                let isReturnKey = event.keyCode == 36 || event.keyCode == 76
                if (normalizedFlags.isEmpty && event.keyCode == 53) ||
                    (isReturnKey && !normalizedFlags.contains(.command)) {
                    super.keyDown(with: event)
                    return finish(true)
                }
                let result = super.performKeyEquivalent(with: event)
                // While focus mode is active, the page gets the shortcut once and cmux/main-menu
                // fallback must not see unhandled command equivalents.
                return finish(result || normalizedFlags.contains(.command))
            case .consume:
                return finish(true)
            }
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            return finish(AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true)
        }

        // Menu/app shortcut routing is only needed for Command equivalents
        // (New Tab, Close Tab, tab switching, split commands, etc).
        guard flags.contains(.command) else {
            return finish(super.performKeyEquivalent(with: event))
        }

        if Self.isPasteAsPlainTextCommandEquivalent(event) {
            if event.timestamp > 0 {
                lastPasteAsPlainTextPerformKeyEventTimestamp = event.timestamp
            } else {
                lastPasteAsPlainTextPerformKeyEventTimestamp = nil
            }
            let result = performPasteAsPlainTextFromPasteboard() || super.performKeyEquivalent(with: event)
            if result {
                lastPasteAsPlainTextPerformKeyEventTimestamp = nil
            }
            return finish(result)
        }

        var replayedBrowserDocumentEditingShortcutIntoWebContent = false
        if shouldRouteBrowserDocumentEditingCommandEquivalentThroughWebContentFirst(
            event,
            responder: window?.firstResponder
        ) {
            replayedBrowserDocumentEditingShortcutIntoWebContent = true
            let result = super.performKeyEquivalent(with: event)
            if result {
                return finish(true)
            }
        }

        var replayedBrowserFindShortcutIntoWebContent = false
        if shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
            event,
            responder: window?.firstResponder,
            owningWebView: self
        ) {
            replayedBrowserFindShortcutIntoWebContent = true
            let result = super.performKeyEquivalent(with: event)
            if result {
                return finish(true)
            }
        }

        if shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(event, pageURL: url) {
            _ = super.performKeyEquivalent(with: event)
            return finish(true)
        }

        if !shouldRouteCommandEquivalentDirectlyToMainMenu(event) {
            return finish(super.performKeyEquivalent(with: event))
        }

        if AppDelegate.shared?.handleBrowserSurfaceKeyEquivalentBeforeMainMenu(event) == true {
            return finish(true)
        }

        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return finish(true)
        }

        let result: Bool
        if replayedBrowserDocumentEditingShortcutIntoWebContent || replayedBrowserFindShortcutIntoWebContent {
            // A browser-first preflight has already exposed this shortcut to WebKit once.
            // Avoid a second `super.performKeyEquivalent` replay when menu/app fallback does not claim it.
            result = false
        } else {
            result = super.performKeyEquivalent(with: event)
        }
        return finish(result)
    }

    override func keyDown(with event: NSEvent) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        var route = "super"
        defer {
            CmuxTypingTiming.logDuration(
                path: "browser.web.keyDown",
                startedAt: typingTimingStart,
                event: event,
                extra: "route=\(route)"
            )
        }
#endif
        if let decision = AppDelegate.shared?.handleBrowserFocusModeKeyEvent(
            event,
            webView: self,
            source: "web.keyDown"
        ), decision != .inactive {
            switch decision {
            case .inactive:
                break
            case .forwardToWebView:
#if DEBUG
                route = "focusModeWebView"
#endif
                super.keyDown(with: event)
                return
            case .consume:
#if DEBUG
                route = "focusModeExit"
#endif
                return
            }
        }

        if Self.isPasteAsPlainTextCommandEquivalent(event) {
            if shouldSkipRepeatedPasteAsPlainTextPreflight(for: event) {
#if DEBUG
                route = "super"
#endif
            } else {
                let didPaste = performPasteAsPlainTextFromPasteboard()
#if DEBUG
                route = didPaste ? "pasteAsPlainText" : "super"
#endif
                if didPaste {
                    return
                }
            }
        }

        // Inline VS Code owns Cmd+Shift+P for its in-page command palette.
        // If this path reaches keyDown, forward it to WebKit instead of cmux.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(event, pageURL: url) {
#if DEBUG
            route = "inlineVSCode"
#endif
            super.keyDown(with: event)
            return
        }

        // Some Cmd-based key paths in WebKit don't consistently invoke performKeyEquivalent.
        // Route them through the same app-level shortcut handler as a fallback.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
#if DEBUG
            route = "appShortcut"
#endif
            return
        }

        super.keyDown(with: event)
    }

    // MARK: - Focus on click

}
