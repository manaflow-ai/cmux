import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Swizzled sendEvent and performKeyEquivalent routing
extension NSWindow {
    @objc func cmux_sendEvent(_ event: NSEvent) {
#if DEBUG
        let typingTimingStart = event.type == .keyDown ? CmuxTypingTiming.start() : nil
        let phaseTotalStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
        var contextSetupMs: Double = 0
        var focusRepairMs: Double = 0
        var folderGuardMs: Double = 0
        var originalDispatchMs: Double = 0
        let typingTimingExtra: String? = {
            guard event.type == .keyDown else { return nil }
            let responderWebView = self.firstResponder.flatMap {
                Self.cmuxOwningWebView(for: $0, in: self, event: event)
            }
            let firstResponderType = self.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            return "browser=\(responderWebView != nil ? 1 : 0) firstResponder=\(firstResponderType)"
        }()
        if event.type == .keyDown {
            CmuxTypingTiming.logEventDelay(path: "window.sendEvent", event: event)
        }
#endif
        // recordTypingActivity must run in all builds so runSessionAutosaveTick
        // can honor the typing quiet period in release.
        if event.type == .keyDown, let app = AppDelegate.shared, cmuxCloseFocusedTerminalFindForEscape(event: event, appDelegate: app) { return }
        if event.type == .keyDown { AppDelegate.shared?.recordTypingActivity() }
        if event.type == .leftMouseDown,
           AppDelegate.shared?.handleMinimalModeSidebarChromeMouseDown(window: self, event: event) == true {
            return
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
                        ("focusRepairMs", focusRepairMs),
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
        cmuxFirstResponderGuardHitViewContext = Self.cmuxHitViewForFirstResponderGuard(in: self, event: event)
        cmuxFirstResponderGuardContextWindowNumber = self.windowNumber
#if DEBUG
        if event.type == .keyDown {
            contextSetupMs = (ProcessInfo.processInfo.systemUptime - contextSetupStart) * 1000.0
        }
        let focusRepairStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif
        if event.type == .keyDown {
            AppDelegate.shared?.repairFocusedTerminalKeyboardRoutingIfNeeded(
                window: self,
                event: event
            )
        }
#if DEBUG
        if event.type == .keyDown {
            focusRepairMs = (ProcessInfo.processInfo.systemUptime - focusRepairStart) * 1000.0
        }
        let folderGuardStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif
        defer {
            cmuxFirstResponderGuardCurrentEventContext = previousContextEvent
            cmuxFirstResponderGuardHitViewContext = previousContextHitView
            cmuxFirstResponderGuardContextWindowNumber = previousContextWindowNumber
        }

        let suppressionReason = beginOrContinueWindowMoveSuppressionSequenceForEvent(window: self, event: event)
        let hasActiveSuppressionSequence = activeWindowMoveSuppressionSequenceReason(window: self) != nil
        guard suppressionReason != nil || hasActiveSuppressionSequence else {
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
        let shouldFinishSuppression = shouldFinishWindowMoveSuppressionSequenceAfterDispatch(window: self, event: event)

#if DEBUG
        let hitView = WindowInputRoutingContext(event: event).allowsPortalPointerHitTesting
            ? Self.cmuxHitViewForEventDispatch(in: self, event: event)
            : nil
#endif
        defer {
            let finishedReason: WindowMoveSuppressionReason?
            if shouldFinishSuppression {
                finishedReason = finishWindowMoveSuppressionSequence(window: self)
            } else {
                finishedReason = nil
            }
            #if DEBUG
            let reasonDescription = finishedReason?.rawValue ?? suppressionReason?.rawValue ?? "activeSequence"
            if shouldFinishSuppression {
                cmuxDebugLog("window.sendEvent.\(reasonDescription) finish nowMovable=\(isMovable)")
            } else {
                cmuxDebugLog("window.sendEvent.\(reasonDescription) keepSuppressed nowMovable=\(isMovable)")
            }
            #endif
        }

        #if DEBUG
        let hitDesc = hitView.map { String(describing: type(of: $0)) } ?? "nil"
        let depth = windowDragSuppressionDepth(window: self)
        let reasonDescription = suppressionReason?.rawValue ?? "activeSequence"
        cmuxDebugLog("window.sendEvent.\(reasonDescription) suppress=1 hit=\(hitDesc) movable=\(isMovable) depth=\(depth)")
        #endif

        cmux_sendEvent(event)
#if DEBUG
        if event.type == .keyDown {
            originalDispatchMs = (ProcessInfo.processInfo.systemUptime - originalDispatchStart) * 1000.0
        }
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
        let frType = self.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        cmuxDebugLog("performKeyEquiv: \(Self.keyDescription(event)) fr=\(frType)")
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
        let firstResponderGhosttyView = cmuxOwningGhosttyView(for: self.firstResponder)
        let firstResponderWebView = self.firstResponder.flatMap {
            Self.cmuxOwningWebView(for: $0, in: self, event: event)
        }
        let firstResponderHasMarkedText = browserResponderHasMarkedText(self.firstResponder)
        let firstResponderIsCommandPaletteFieldEditor = Self.cmuxCommandPaletteOwnsFieldEditor(
            self.firstResponder as? NSTextView,
            in: self
        )
        let firstResponderOmnibarPanelId = browserOmnibarPanelId(for: self.firstResponder)
        let firstResponderIsTextBoxInput = self.firstResponder is TextBoxInputTextView
        // A standalone editable document text view (e.g. the file-preview
        // editor's SavingTextView) owns arrow navigation through its own
        // keyDown. Field editors (omnibar / command palette / find) are
        // excluded — they route through their dedicated paths above.
        let firstResponderIsStandaloneEditableTextView: Bool = {
            guard let textView = self.firstResponder as? NSTextView else { return false }
            return textView.isEditable && !textView.isFieldEditor
        }()
        if ShortcutRecorderEventRouter.dispatchActiveRecordingEvent(event, preferredWindow: self) {
            return true
        }
        if shortcutRoutingShouldBypassForPrintableOptionText(event: event) {
            let textInputTarget: NSResponder? = firstResponderGhosttyView
                ?? firstResponderWebView
                ?? self.firstResponder
            if let textInputTarget, textInputTarget !== self {
                textInputTarget.keyDown(with: event)
#if DEBUG
                cmuxDebugLog("  → printable Option text routed to keyDown")
#endif
                return true
            }
            return false
        }
        if let mode = RightSidebarMode.modeShortcut(for: event),
           AppDelegate.shared?.shouldRouteRightSidebarModeShortcut(in: self) == true {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: self
            )
            return true
        }
        if AppDelegate.shared?.shouldSuppressStaleCmuxMenuShortcut(event: event) == true {
            if AppDelegate.shared?.handleConfiguredShortcutKeyEquivalent(event) == true {
#if DEBUG
                cmuxDebugLog("  → consumed by configured shortcut before stale cmux menu shortcut")
#endif
                return true
            }
            if let firstResponderGhosttyView {
                firstResponderGhosttyView.keyDown(with: event)
#if DEBUG
                cmuxDebugLog("  → terminal received command equivalent bypassing stale cmux menu shortcut")
#endif
                return true
            }
#if DEBUG
            cmuxDebugLog("  → suppressed stale cmux menu shortcut")
#endif
            return false
        }

        if let ghosttyView = firstResponderGhosttyView {
            // If the IME is composing and the key has no Cmd modifier, don't intercept —
            // let it flow through normal AppKit event dispatch so the input method can
            // process it. Cmd-based shortcuts should still work during composition since
            // Cmd is never part of IME input sequences.
            if ghosttyView.hasMarkedText(), !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
                return false
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.command) {
                let result = ghosttyView.performKeyEquivalent(with: event)
#if DEBUG
                cmuxDebugLog("  → ghostty direct: \(result)")
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
                cmuxDebugLog("zoom.shortcut stage=window.ghosttyKeyDownDirect event=\(Self.keyDescription(event)) handled=1")
#endif
                return true
            }
        }

        if browserOmnibarShouldBypassShortcutRoutingForMarkedText(
            hasFocusedAddressBar: firstResponderOmnibarPanelId != nil,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            if cmuxBrowserOmnibarMarkedTextForwardingDepth > 0 {
#if DEBUG
                cmuxDebugLog("  → browser omnibar marked-text reentry; leaving unhandled")
#endif
                return false
            }
            cmuxBrowserOmnibarMarkedTextForwardingDepth += 1
            defer {
                cmuxBrowserOmnibarMarkedTextForwardingDepth = max(
                    0,
                    cmuxBrowserOmnibarMarkedTextForwardingDepth - 1
                )
            }
#if DEBUG
            cmuxDebugLog(
                "  → browser omnibar marked-text routed to firstResponder.keyDown " +
                "panel=\(firstResponderOmnibarPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil")"
            )
#endif
            self.firstResponder?.keyDown(with: event)
            return true
        }

        if shouldDispatchCommandPaletteHorizontalArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsCommandPaletteFieldEditor: firstResponderIsCommandPaletteFieldEditor,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            if cmuxCommandPaletteArrowForwardingDepth > 0 {
                return false
            }
            cmuxCommandPaletteArrowForwardingDepth += 1
            defer { cmuxCommandPaletteArrowForwardingDepth = max(0, cmuxCommandPaletteArrowForwardingDepth - 1) }
            self.firstResponder?.keyDown(with: event)
            return true
        }

        if shouldDispatchBrowserOmnibarArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsBrowserOmnibar: firstResponderOmnibarPanelId != nil,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            if cmuxBrowserArrowForwardingDepth > 0 {
#if DEBUG
                cmuxDebugLog("  → browser omnibar arrow reentry; using normal dispatch")
#endif
                return cmux_performKeyEquivalent(with: event)
            }
            cmuxBrowserArrowForwardingDepth += 1
            defer { cmuxBrowserArrowForwardingDepth = max(0, cmuxBrowserArrowForwardingDepth - 1) }
#if DEBUG
            cmuxDebugLog(
                "  → browser omnibar arrow routed to firstResponder.keyDown " +
                "panel=\(firstResponderOmnibarPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil")"
            )
#endif
            self.firstResponder?.keyDown(with: event)
            return true
        }

        if shouldDispatchTextBoxInputArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsTextBoxInput: firstResponderIsTextBoxInput,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            if cmuxTextBoxInputArrowForwardingDepth > 0 {
                return false
            }
            cmuxTextBoxInputArrowForwardingDepth += 1
            defer { cmuxTextBoxInputArrowForwardingDepth = max(0, cmuxTextBoxInputArrowForwardingDepth - 1) }
            self.firstResponder?.keyDown(with: event)
            return true
        }

        if shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
            charactersIgnoringModifiers: KeyboardLayout.normalizedCharacters(for: event),
            firstResponderIsTextBoxInput: firstResponderIsTextBoxInput,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            if cmuxTextBoxInputControlNavForwardingDepth > 0 {
                return false
            }
            cmuxTextBoxInputControlNavForwardingDepth += 1
            defer { cmuxTextBoxInputControlNavForwardingDepth = max(0, cmuxTextBoxInputControlNavForwardingDepth - 1) }
            self.firstResponder?.keyDown(with: event)
            return true
        }

        // The file-preview editor and any other standalone editable NSTextView
        // would otherwise lose plain/selection/word/line arrows to the original
        // NSWindow.performKeyEquivalent. Route them to the text view's keyDown so
        // arrow navigation works as in any text editor (manaflow-ai/cmux#5227).
        if shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsEditableTextView: firstResponderIsStandaloneEditableTextView,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            if cmuxEditableTextViewArrowForwardingDepth > 0 {
                return false
            }
            cmuxEditableTextViewArrowForwardingDepth += 1
            defer { cmuxEditableTextViewArrowForwardingDepth = max(0, cmuxEditableTextViewArrowForwardingDepth - 1) }
            self.firstResponder?.keyDown(with: event)
            return true
        }

        // Web forms rely on Return/Enter flowing through keyDown. If the original
        // NSWindow.performKeyEquivalent consumes Enter first, submission never reaches
        // WebKit. Route Return/Enter directly to the current first responder and
        // mark handled to avoid the AppKit alert sound path.
        if shouldDispatchBrowserReturnViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsBrowser: firstResponderWebView != nil,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            // Forwarding keyDown can re-enter performKeyEquivalent in WebKit/AppKit internals.
            // On re-entry, fall back to normal dispatch to avoid an infinite loop.
            if cmuxBrowserReturnForwardingDepth > 0 {
#if DEBUG
                cmuxDebugLog("  → browser Return/Enter reentry; using normal dispatch")
#endif
                return cmux_performKeyEquivalent(with: event)
            }
            cmuxBrowserReturnForwardingDepth += 1
            defer { cmuxBrowserReturnForwardingDepth = max(0, cmuxBrowserReturnForwardingDepth - 1) }
#if DEBUG
            cmuxDebugLog("  → browser Return/Enter routed to firstResponder.keyDown")
#endif
            self.firstResponder?.keyDown(with: event)
            return true
        }

        // Some browser content (notably Google Docs) loses plain arrows when
        // NSWindow.performKeyEquivalent claims the arrow before WebKit sees
        // keyDown. Route those arrows directly to the first responder instead.
        if shouldDispatchBrowserArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsBrowser: firstResponderWebView != nil,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            if let focusedOmnibarField = AppDelegate.shared?.focusedBrowserOmnibarField(for: event, in: self),
               browserOmnibarPanelId(for: self.firstResponder) == nil,
               focusedOmnibarField.window === self {
                if cmuxBrowserArrowForwardingDepth > 0 {
#if DEBUG
                    cmuxDebugLog("  → browser arrow omnibar restore reentry; using normal dispatch")
#endif
                    return cmux_performKeyEquivalent(with: event)
                }
                cmuxBrowserArrowForwardingDepth += 1
                defer { cmuxBrowserArrowForwardingDepth = max(0, cmuxBrowserArrowForwardingDepth - 1) }

                var currentEditorResponder: NSResponder? = focusedOmnibarField.currentEditor()
                if currentEditorResponder == nil || self.firstResponder !== currentEditorResponder {
                    guard self.makeFirstResponder(focusedOmnibarField) else {
#if DEBUG
                        cmuxDebugLog("  → browser arrow omnibar restore rejected")
#endif
                        return false
                    }
                    currentEditorResponder = focusedOmnibarField.currentEditor()
                }

                let omnibarResponder: NSResponder
                if let currentEditorResponder, self.firstResponder === currentEditorResponder {
                    omnibarResponder = currentEditorResponder
                } else if self.firstResponder === focusedOmnibarField {
                    omnibarResponder = focusedOmnibarField
                } else {
#if DEBUG
                    cmuxDebugLog("  → browser arrow omnibar restore did not become first responder")
#endif
                    return false
                }
#if DEBUG
                if browserResponderHasMarkedText(omnibarResponder) {
                    cmuxDebugLog("  → browser arrow restored focused omnibar with marked text before keyDown")
                } else {
                    cmuxDebugLog("  → browser arrow restored focused omnibar before keyDown")
                }
#endif
                omnibarResponder.keyDown(with: event)
                return true
            }

            // Match the Return/Enter forwarding guard: AppKit/WebKit can re-enter
            // performKeyEquivalent while the synthesized keyDown is in flight.
            if cmuxBrowserArrowForwardingDepth > 0 {
#if DEBUG
                cmuxDebugLog("  → browser arrow reentry; using normal dispatch")
#endif
                return cmux_performKeyEquivalent(with: event)
            }
            cmuxBrowserArrowForwardingDepth += 1
            defer { cmuxBrowserArrowForwardingDepth = max(0, cmuxBrowserArrowForwardingDepth - 1) }
#if DEBUG
            cmuxDebugLog("  → browser arrow routed to firstResponder.keyDown")
#endif
            self.firstResponder?.keyDown(with: event)
            return true
        }

        if let firstResponderWebView,
           AppDelegate.shared?.isBrowserFocusModeActive(for: firstResponderWebView) == true {
            let handled = firstResponderWebView.performKeyEquivalent(with: event)
#if DEBUG
            cmuxDebugLog("  → browser focus mode routed before cmux/menu fallback handled=\(handled ? 1 : 0)")
#endif
            return handled
        }

        if let firstResponderWebView,
           shouldRouteBrowserDocumentEditingCommandEquivalentThroughWebContentFirst(
               event,
               responder: self.firstResponder
           ) {
            let result = firstResponderWebView.performKeyEquivalent(with: event)
#if DEBUG
            cmuxDebugLog(
                "  → browser document editing command preflight " +
                (result ? "resolved before window menu path" : "left unclaimed; suppressing replay")
            )
#endif
            // The focused web view has already received this editing shortcut once.
            // `CmuxWebView.performKeyEquivalent` also runs the main-menu fallback
            // before returning, so falling through here would only replay WebKit.
            return true
        }

        if let firstResponderWebView,
           shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
               event,
               responder: self.firstResponder,
               owningWebView: firstResponderWebView
           ) {
            let result = firstResponderWebView.performKeyEquivalent(with: event)
#if DEBUG
            if result {
                cmuxDebugLog("  → browser find command resolved before window menu path")
            } else {
                cmuxDebugLog("  → browser find command preflight left unclaimed; suppressing replay")
            }
#endif
            // The focused web view has already received this Find-family shortcut once.
            // Do not fall through into the original NSWindow.performKeyEquivalent path,
            // or WebKit can observe the same key equivalent a second time before AppKit
            // reaches keyDown/menu fallback.
            return true
        }

        if AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
#if DEBUG
            cmuxDebugLog("  → consumed by handleBrowserSurfaceKeyEquivalent")
#endif
            return true
        }

        if let firstResponderGhosttyView, shouldRouteCommandEquivalentDirectlyToMainMenu(event) {
            if AppDelegate.shared?.shouldForwardBrowserSurfaceShortcutToTerminal(event) == true {
                if firstResponderGhosttyView.performKeyEquivalentAfterMenuMiss(with: event) { return true }
                firstResponderGhosttyView.keyDown(with: event)
                return true
            }
            guard let mainMenu = NSApp.mainMenu else { return false }
            let consumedByMenu = mainMenu.performKeyEquivalent(with: event)
#if DEBUG
            if browserZoomShortcutTraceCandidate(
                flags: event.modifierFlags,
                chars: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode,
                literalChars: event.characters
            ) {
                cmuxDebugLog(
                    "zoom.shortcut stage=window.mainMenuBypass event=\(Self.keyDescription(event)) " +
                    "consumed=\(consumedByMenu ? 1 : 0) fr=GhosttyNSView"
                )
            }
#endif
            if !consumedByMenu {
                // After a direct-to-menu miss, let Ghostty resolve the command key
                // through its normal binding path so user key overrides still win.
                let consumedByGhostty = firstResponderGhosttyView.performKeyEquivalentAfterMenuMiss(with: event)
#if DEBUG
                cmuxDebugLog("  → mainMenu miss; ghostty command path: \(consumedByGhostty)")
#endif
                if consumedByGhostty {
                    return true
                }
            } else {
#if DEBUG
                cmuxDebugLog("  → consumed by mainMenu (bypassed SwiftUI)")
#endif
                return true
            }
        }

        let result = cmux_performKeyEquivalent(with: event)
#if DEBUG
        if result { cmuxDebugLog("  → consumed by original performKeyEquivalent") }
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
        let chars: String
        if event.type == .keyDown || event.type == .keyUp {
            chars = event.charactersIgnoringModifiers ?? "?"
        } else {
            chars = String(describing: event.type)
        }
        parts.append("'\(chars)'(\(event.keyCode))")
        return parts.joined(separator: "+")
    }

}
