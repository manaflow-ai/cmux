//
//  cmuxApp+ExtendedTypes.swift
//  cmux
//
//  Created by Gale Williams on 3/16/26.
//

import AppKit
import Bonsplit
import SwiftUI

extension View {
    @ViewBuilder
    func applyIf(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

extension NSApplication {
    @objc func cmux_applicationSendEvent(_ event: NSEvent) {
        #if DEBUG
            let typingTimingStart = event.type == .keyDown ? CmuxTypingTiming.start() : nil
            let phaseTotalStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
            if event.type == .keyDown {
                CmuxTypingTiming.logEventDelay(path: "app.sendEvent", event: event)
            }
            defer {
                if event.type == .keyDown {
                    let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                    CmuxTypingTiming.logBreakdown(
                        path: "app.sendEvent.phase",
                        totalMs: totalMs,
                        event: event,
                        thresholdMs: 1.0,
                        parts: [("dispatchMs", totalMs)]
                    )
                    CmuxTypingTiming.logDuration(
                        path: "app.sendEvent",
                        startedAt: typingTimingStart,
                        event: event
                    )
                }
            }
        #endif
        cmux_applicationSendEvent(event)
    }
}

extension NSScreen {
    var cmuxDisplayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let value = deviceDescription[key] as? NSNumber else { return nil }
        return value.uint32Value
    }
}

extension NSWindow {
    @objc func cmux_makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if cmuxIsWindowFirstResponderBypassActive() {
            #if DEBUG
                dlog(
                    "focus.guard bypassFirstResponder responder=\(String(describing: responder.map { type(of: $0) })) " +
                        "window=\(ObjectIdentifier(self))"
                )
            #endif
            return false
        }

        let currentEvent = Self.cmuxCurrentEvent(for: self)
        let responderWebView = responder.flatMap {
            Self.cmuxOwningWebView(for: $0, in: self, event: currentEvent)
        }
        var pointerInitiatedWebFocus = false

        if AppDelegate.shared?.shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
            window: self,
            responder: responder
        ) == true {
            #if DEBUG
                dlog(
                    "focus.guard commandPaletteBlocked responder=\(String(describing: responder.map { type(of: $0) })) " +
                        "window=\(ObjectIdentifier(self))"
                )
            #endif
            return false
        }

        if let responder,
           let webView = responderWebView,
           !webView.allowsFirstResponderAcquisitionEffective
        {
            let pointerInitiatedFocus = Self.cmuxShouldAllowPointerInitiatedWebViewFocus(
                window: self,
                webView: webView,
                event: currentEvent
            )
            if pointerInitiatedFocus {
                pointerInitiatedWebFocus = true
                #if DEBUG
                    dlog(
                        "focus.guard allowPointerFirstResponder responder=\(String(describing: type(of: responder))) " +
                            "window=\(ObjectIdentifier(self)) " +
                            "web=\(ObjectIdentifier(webView)) " +
                            "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                            "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                            "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                    )
                #endif
            } else {
                #if DEBUG
                    dlog(
                        "focus.guard blockedFirstResponder responder=\(String(describing: type(of: responder))) " +
                            "window=\(ObjectIdentifier(self)) " +
                            "web=\(ObjectIdentifier(webView)) " +
                            "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                            "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                            "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                    )
                #endif
                return false
            }
        }
        #if DEBUG
            if let responder,
               let webView = responderWebView
            {
                dlog(
                    "focus.guard allowFirstResponder responder=\(String(describing: type(of: responder))) " +
                        "window=\(ObjectIdentifier(self)) " +
                        "web=\(ObjectIdentifier(webView)) " +
                        "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                        "pointerDepth=\(webView.debugPointerFocusAllowanceDepth)"
                )
            }
        #endif
        let result: Bool = if pointerInitiatedWebFocus, let webView = responderWebView {
            // `NSWindow.makeFirstResponder` may run before `CmuxWebView.mouseDown(with:)`.
            // Preserve pointer intent during this synchronous responder change.
            webView.withPointerFocusAllowance {
                cmux_makeFirstResponder(responder)
            }
        } else {
            cmux_makeFirstResponder(responder)
        }
        if result {
            if let fieldEditor = responder as? NSTextView, fieldEditor.isFieldEditor {
                Self.cmuxTrackFieldEditor(fieldEditor, owningWebView: responderWebView)
            } else if let fieldEditor = firstResponder as? NSTextView, fieldEditor.isFieldEditor {
                Self.cmuxTrackFieldEditor(fieldEditor, owningWebView: responderWebView)
            }
        }
        return result
    }

    @objc func cmux_sendEvent(_ event: NSEvent) {
        #if DEBUG
            let typingTimingStart = event.type == .keyDown ? CmuxTypingTiming.start() : nil
            let phaseTotalStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
            var contextSetupMs: Double = 0
            var folderGuardMs: Double = 0
            var originalDispatchMs: Double = 0
            let typingTimingExtra: String? = {
                guard event.type == .keyDown else { return nil }
                let responderWebView = self.firstResponder.flatMap {
                    Self.cmuxOwningWebView(for: $0, in: self, event: event)
                }
                let hitWebView = Self.cmuxHitViewForEventDispatch(in: self, event: event).flatMap {
                    Self.cmuxOwningWebView(for: $0)
                }
                let firstResponderType = self.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                return "browser=\((responderWebView != nil || hitWebView != nil) ? 1 : 0) firstResponder=\(firstResponderType)"
            }()
            if event.type == .keyDown {
                CmuxTypingTiming.logEventDelay(path: "window.sendEvent", event: event)
            }
        #endif
        // recordTypingActivity must run in all builds so runSessionAutosaveTick
        // can honor the typing quiet period in release.
        if event.type == .keyDown {
            AppDelegate.shared?.recordTypingActivity()
        }
        #if DEBUG
            defer {
                if event.type == .keyDown {
                    let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                    CmuxTypingTiming.logBreakdown(
                        path: "window.sendEvent.phase",
                        totalMs: totalMs,
                        event: event,
                        thresholdMs: 1.0,
                        parts: [
                            ("contextSetupMs", contextSetupMs),
                            ("folderGuardMs", folderGuardMs),
                            ("originalDispatchMs", originalDispatchMs),
                        ],
                        extra: typingTimingExtra
                    )
                    CmuxTypingTiming.logDuration(
                        path: "window.sendEvent",
                        startedAt: typingTimingStart,
                        event: event,
                        extra: typingTimingExtra
                    )
                }
            }
            let contextSetupStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
        #endif
        let previousContextEvent = cmuxFirstResponderGuardCurrentEventContext
        let previousContextHitView = cmuxFirstResponderGuardHitViewContext
        let previousContextWindowNumber = cmuxFirstResponderGuardContextWindowNumber
        cmuxFirstResponderGuardCurrentEventContext = event
        cmuxFirstResponderGuardHitViewContext = Self.cmuxHitViewForEventDispatch(in: self, event: event)
        cmuxFirstResponderGuardContextWindowNumber = windowNumber
        #if DEBUG
            if event.type == .keyDown {
                contextSetupMs = (ProcessInfo.processInfo.systemUptime - contextSetupStart) * 1000.0
            }
            let folderGuardStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
        #endif
        defer {
            cmuxFirstResponderGuardCurrentEventContext = previousContextEvent
            cmuxFirstResponderGuardHitViewContext = previousContextHitView
            cmuxFirstResponderGuardContextWindowNumber = previousContextWindowNumber
        }

        guard shouldSuppressWindowMoveForFolderDrag(window: self, event: event),
              let contentView
        else {
            #if DEBUG
                if event.type == .keyDown {
                    folderGuardMs = (ProcessInfo.processInfo.systemUptime - folderGuardStart) * 1000.0
                    let originalDispatchStart = ProcessInfo.processInfo.systemUptime
                    cmux_sendEvent(event)
                    originalDispatchMs = (ProcessInfo.processInfo.systemUptime - originalDispatchStart) * 1000.0
                    return
                }
            #endif
            cmux_sendEvent(event)
            return
        }
        #if DEBUG
            if event.type == .keyDown {
                folderGuardMs = (ProcessInfo.processInfo.systemUptime - folderGuardStart) * 1000.0
            }
            let originalDispatchStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
        #endif

        let contentPoint = contentView.convert(event.locationInWindow, from: nil)
        let hitView = contentView.hitTest(contentPoint)
        let previousMovableState = isMovable
        if previousMovableState {
            isMovable = false
        }

        #if DEBUG
            let hitDesc = hitView.map { String(describing: type(of: $0)) } ?? "nil"
            dlog("window.sendEvent.folderDown suppress=1 hit=\(hitDesc) wasMovable=\(previousMovableState)")
        #endif

        cmux_sendEvent(event)
        #if DEBUG
            if event.type == .keyDown {
                originalDispatchMs = (ProcessInfo.processInfo.systemUptime - originalDispatchStart) * 1000.0
            }
        #endif

        if previousMovableState {
            isMovable = previousMovableState
        }

        #if DEBUG
            dlog("window.sendEvent.folderDown restore nowMovable=\(isMovable)")
        #endif
    }

    @objc func cmux_performKeyEquivalent(with event: NSEvent) -> Bool {
        #if DEBUG
            let typingTimingStart = CmuxTypingTiming.start()
            defer {
                CmuxTypingTiming.logDuration(
                    path: "window.performKeyEquivalent",
                    startedAt: typingTimingStart,
                    event: event
                )
            }
            let frType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            dlog("performKeyEquiv: \(Self.keyDescription(event)) fr=\(frType)")
        #endif

        // When the terminal surface is the first responder, prevent SwiftUI's
        // hosting view from consuming key events via performKeyEquivalent.
        // After a browser panel (WKWebView) has been in the responder chain,
        // SwiftUI's internal focus system can get into a broken state where it
        // intercepts key events in the content view hierarchy, returns true
        // (claiming consumption), but never actually fires the action closure.
        //
        // For non-Command keys: bypass the view hierarchy entirely and send
        // directly to the terminal so arrow keys, Ctrl+N/P, etc. reach keyDown.
        //
        // For Command keys: bypass the SwiftUI content view hierarchy and
        // dispatch directly to the main menu. No SwiftUI view should be handling
        // Command shortcuts when the terminal is focused — the local event monitor
        // (handleCustomShortcut) already handles app-level shortcuts, and anything
        // remaining should be menu items.
        let firstResponderGhosttyView = cmuxOwningGhosttyView(for: firstResponder)
        let firstResponderWebView = firstResponder.flatMap {
            Self.cmuxOwningWebView(for: $0, in: self, event: event)
        }
        if let ghosttyView = firstResponderGhosttyView {
            // If the IME is composing and the key has no Cmd modifier, don't intercept —
            // let it flow through normal AppKit event dispatch so the input method can
            // process it. Cmd-based shortcuts should still work during composition since
            // Cmd is never part of IME input sequences.
            if ghosttyView.hasMarkedText(), !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
                return cmux_performKeyEquivalent(with: event)
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.command) {
                let result = ghosttyView.performKeyEquivalent(with: event)
                #if DEBUG
                    dlog("  → ghostty direct: \(result)")
                #endif
                return result
            }

            // Preserve Ghostty's terminal font-size shortcuts (Cmd +/−/0) when
            // the terminal is focused. Otherwise our browser menu shortcuts can
            // consume the event even when no browser panel is focused.
            if shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: event.modifierFlags,
                chars: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode,
                literalChars: event.characters
            ) {
                ghosttyView.keyDown(with: event)
                #if DEBUG
                    dlog("zoom.shortcut stage=window.ghosttyKeyDownDirect event=\(Self.keyDescription(event)) handled=1")
                #endif
                return true
            }
        }

        // Web forms rely on Return/Enter flowing through keyDown. If the original
        // NSWindow.performKeyEquivalent consumes Enter first, submission never reaches
        // WebKit. Route Return/Enter directly to the current first responder and
        // mark handled to avoid the AppKit alert sound path.
        if shouldDispatchBrowserReturnViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsBrowser: firstResponderWebView != nil,
            flags: event.modifierFlags
        ) {
            // Forwarding keyDown can re-enter performKeyEquivalent in WebKit/AppKit internals.
            // On re-entry, fall back to normal dispatch to avoid an infinite loop.
            if cmuxBrowserReturnForwardingDepth > 0 {
                #if DEBUG
                    dlog("  → browser Return/Enter reentry; using normal dispatch")
                #endif
                return false
            }
            cmuxBrowserReturnForwardingDepth += 1
            defer { cmuxBrowserReturnForwardingDepth = max(0, cmuxBrowserReturnForwardingDepth - 1) }
            #if DEBUG
                dlog("  → browser Return/Enter routed to firstResponder.keyDown")
            #endif
            firstResponder?.keyDown(with: event)
            return true
        }

        if AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
            #if DEBUG
                dlog("  → consumed by handleBrowserSurfaceKeyEquivalent")
            #endif
            return true
        }

        // When the terminal is focused, skip the full NSWindow.performKeyEquivalent
        // (which walks the SwiftUI content view hierarchy) and dispatch Command-key
        // events directly to the main menu. This avoids the broken SwiftUI focus path.
        if firstResponderGhosttyView != nil,
           shouldRouteCommandEquivalentDirectlyToMainMenu(event),
           let mainMenu = NSApp.mainMenu
        {
            let consumedByMenu = mainMenu.performKeyEquivalent(with: event)
            #if DEBUG
                if browserZoomShortcutTraceCandidate(
                    flags: event.modifierFlags,
                    chars: event.charactersIgnoringModifiers ?? "",
                    keyCode: event.keyCode,
                    literalChars: event.characters
                ) {
                    dlog(
                        "zoom.shortcut stage=window.mainMenuBypass event=\(Self.keyDescription(event)) " +
                            "consumed=\(consumedByMenu ? 1 : 0) fr=GhosttyNSView"
                    )
                }
            #endif
            if !consumedByMenu {
                // Fall through to the original performKeyEquivalent path below.
            } else {
                #if DEBUG
                    dlog("  → consumed by mainMenu (bypassed SwiftUI)")
                #endif
                return true
            }
        }

        let result = cmux_performKeyEquivalent(with: event)
        #if DEBUG
            if result { dlog("  → consumed by original performKeyEquivalent") }
        #endif
        return result
    }

    static func keyDescription(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { parts.append("Cmd") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.option) { parts.append("Opt") }
        if flags.contains(.control) { parts.append("Ctrl") }
        let chars = event.charactersIgnoringModifiers ?? "?"
        parts.append("'\(chars)'(\(event.keyCode))")
        return parts.joined(separator: "+")
    }

    private static func cmuxOwningWebView(for responder: NSResponder) -> CmuxWebView? {
        if let webView = responder as? CmuxWebView {
            return webView
        }

        if let view = responder as? NSView,
           let webView = cmuxOwningWebView(for: view)
        {
            return webView
        }

        // NSTextView.delegate is unsafe-unretained in AppKit. Reading it here while
        // a responder chain is tearing down can trap with "unowned reference".
        var current = responder.nextResponder
        while let next = current {
            if let webView = next as? CmuxWebView {
                return webView
            }
            if let view = next as? NSView,
               let webView = cmuxOwningWebView(for: view)
            {
                return webView
            }
            current = next.nextResponder
        }

        return nil
    }

    private static func cmuxOwningWebView(
        for responder: NSResponder,
        in window: NSWindow,
        event: NSEvent?
    ) -> CmuxWebView? {
        if let webView = cmuxOwningWebView(for: responder) {
            return webView
        }

        guard let textView = responder as? NSTextView, textView.isFieldEditor else {
            return nil
        }

        if let event,
           let hitWebView = cmuxPointerHitWebView(in: window, event: event)
        {
            cmuxTrackFieldEditor(textView, owningWebView: hitWebView)
            return hitWebView
        }

        return cmuxTrackedOwningWebView(for: textView)
    }

    private static func cmuxOwningWebView(for view: NSView) -> CmuxWebView? {
        if let webView = view as? CmuxWebView {
            return webView
        }

        var current: NSView? = view.superview
        while let candidate = current {
            if let webView = candidate as? CmuxWebView {
                return webView
            }
            if String(describing: type(of: candidate)).contains("WindowBrowserSlotView"),
               let portalWebView = cmuxUniqueBrowserWebView(in: candidate)
            {
                // Portal-hosted browser chrome (for example the Cmd+F overlay) is a
                // sibling of the hosted WKWebView inside WindowBrowserSlotView, not a
                // descendant of it. Treating every view in that slot as "web-owned"
                // blocks legitimate first-responder changes to overlay text fields.
                if view === portalWebView || view.isDescendant(of: portalWebView) {
                    return portalWebView
                }
                return nil
            }
            current = candidate.superview
        }

        return nil
    }

    private static func cmuxUniqueBrowserWebView(in root: NSView) -> CmuxWebView? {
        var stack: [NSView] = [root]
        var found: CmuxWebView?
        while let current = stack.popLast() {
            if let webView = current as? CmuxWebView {
                if found == nil {
                    found = webView
                } else if found !== webView {
                    return nil
                }
            }
            stack.append(contentsOf: current.subviews)
        }
        return found
    }

    private static func cmuxCurrentEvent(for window: NSWindow) -> NSEvent? {
        #if DEBUG
            if let override = cmuxFirstResponderGuardCurrentEventOverride {
                return override
            }
        #endif
        if cmuxFirstResponderGuardContextWindowNumber == window.windowNumber {
            return cmuxFirstResponderGuardCurrentEventContext
        }
        return NSApp.currentEvent
    }

    private static func cmuxHitViewInThemeFrame(in window: NSWindow, event: NSEvent) -> NSView? {
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview
        else {
            return nil
        }
        let pointInTheme = themeFrame.convert(event.locationInWindow, from: nil)
        return themeFrame.hitTest(pointInTheme)
    }

    private static func cmuxHitViewInContentView(in window: NSWindow, event: NSEvent) -> NSView? {
        guard let contentView = window.contentView else {
            return nil
        }
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)
        return contentView.hitTest(pointInContent)
    }

    private static func cmuxTopHitViewForEvent(in window: NSWindow, event: NSEvent) -> NSView? {
        if let hitInThemeFrame = cmuxHitViewInThemeFrame(in: window, event: event) {
            return hitInThemeFrame
        }
        return cmuxHitViewInContentView(in: window, event: event)
    }

    private static func cmuxHitViewForEventDispatch(in window: NSWindow, event: NSEvent) -> NSView? {
        if event.windowNumber != 0, event.windowNumber != window.windowNumber {
            return nil
        }
        if let eventWindow = event.window, eventWindow !== window {
            return nil
        }
        return cmuxTopHitViewForEvent(in: window, event: event)
    }

    private static func cmuxHitViewForCurrentEvent(in window: NSWindow, event: NSEvent) -> NSView? {
        #if DEBUG
            if let override = cmuxFirstResponderGuardHitViewOverride {
                return override
            }
        #endif
        if cmuxFirstResponderGuardContextWindowNumber == window.windowNumber,
           let contextHitView = cmuxFirstResponderGuardHitViewContext
        {
            return contextHitView
        }
        return cmuxTopHitViewForEvent(in: window, event: event)
    }

    private static func cmuxTrackFieldEditor(_ fieldEditor: NSTextView, owningWebView webView: CmuxWebView?) {
        if let webView {
            objc_setAssociatedObject(
                fieldEditor,
                &cmuxFieldEditorOwningWebViewAssociationKey,
                CmuxFieldEditorOwningWebViewBox(webView: webView),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        } else {
            objc_setAssociatedObject(
                fieldEditor,
                &cmuxFieldEditorOwningWebViewAssociationKey,
                nil,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    private static func cmuxTrackedOwningWebView(for fieldEditor: NSTextView) -> CmuxWebView? {
        guard let box = objc_getAssociatedObject(
            fieldEditor,
            &cmuxFieldEditorOwningWebViewAssociationKey
        ) as? CmuxFieldEditorOwningWebViewBox else {
            return nil
        }
        guard let webView = box.webView else {
            cmuxTrackFieldEditor(fieldEditor, owningWebView: nil)
            return nil
        }
        return webView
    }

    private static func cmuxIsPointerDownEvent(_ event: NSEvent) -> Bool {
        switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                true
            default:
                false
        }
    }

    private static func cmuxPointerHitWebView(in window: NSWindow, event: NSEvent) -> CmuxWebView? {
        guard cmuxIsPointerDownEvent(event) else { return nil }
        if event.windowNumber != 0, event.windowNumber != window.windowNumber {
            return nil
        }
        if let eventWindow = event.window, eventWindow !== window {
            return nil
        }
        if let portalWebView = BrowserWindowPortalRegistry.webViewAtWindowPoint(
            event.locationInWindow,
            in: window
        ) as? CmuxWebView {
            return portalWebView
        }
        guard let hitView = cmuxHitViewForCurrentEvent(in: window, event: event) else {
            return nil
        }
        return cmuxOwningWebView(for: hitView)
    }

    private static func cmuxShouldAllowPointerInitiatedWebViewFocus(
        window: NSWindow,
        webView: CmuxWebView,
        event: NSEvent?
    ) -> Bool {
        guard let event,
              let hitWebView = cmuxPointerHitWebView(in: window, event: event)
        else {
            return false
        }
        return hitWebView === webView
    }
}
