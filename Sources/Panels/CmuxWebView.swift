import AppKit
import Bonsplit
import CmuxBrowser
import ObjectiveC
import UniformTypeIdentifiers
import WebKit
#if DEBUG
import CmuxTestSupport
#endif

// `WKWebView.cmuxSetPageAudioMuted(_:)` plus its private selector/state helpers,
// and `cmuxIsElementFullscreenActiveOrTransitioning` /
// `cmuxIsManagedByExternalFullscreenWindow(relativeTo:)` moved to CmuxBrowser
// (CmuxBrowser/Navigation/WKWebView+PageAudioMute.swift and
// WKWebView+ElementFullscreen.swift); callers reach them via the existing
// `import CmuxBrowser` at the top of this file.

// `BrowserImageCopyPasteboardPayload` (value struct owning its own
// `pasteboardItems` formatting; the former `BrowserImageCopyPasteboardBuilder`
// caseless namespace was dissolved into it) moved to
// `CmuxBrowser/Pasteboard/BrowserImageCopyPasteboardPayload.swift`; callers reach
// it via the existing `import CmuxBrowser` at the top of this file.

// `BrowserFocusModeKeyDecision` moved to
// `CmuxBrowser/Focus/BrowserFocusModeKeyDecision.swift` alongside the pure
// `BrowserFocusModeEscapeMachine` that produces it (imported via CmuxBrowser).

/// WKWebView tends to consume some app command equivalents,
/// preventing the app menu/SwiftUI Commands from receiving them. Route app/menu
/// shortcuts first by default, but allow browser content to try browser-local
/// Find-family shortcuts. The configured Find shortcut stays app-owned so cmux can
/// choose browser find or right-sidebar file search from the current focus owner.
final class CmuxWebView: WKWebView {
    // Some sites/WebKit paths report middle-click link activations as
    // WKNavigationAction.buttonNumber=4 instead of 2. The recent-middle-click
    // store moved to `BrowserMiddleClickIntentTracker` in
    // `CmuxBrowser/Navigation`; this view holds an injected instance and records
    // into it on `otherMouseDown`/`otherMouseUp`. The navigation/UI delegates read
    // through the same held instance via `hasRecentMiddleClickIntent`.
    let middleClickIntentTracker: BrowserMiddleClickIntentTracker

    /// Pure URL classification for the context-menu download/copy paths, owned in
    /// `CmuxBrowser`. This view forwards the scheme/favicon/image/redirect/MIME
    /// predicates to it (through `contextDownloadService`, which holds it).
    private let downloadURLClassifier = BrowserDownloadURLClassifier()
    /// Classifies resolved context-menu candidate URLs into a typed
    /// download / try-next / native-fallback decision, owned in `CmuxBrowser`.
    /// The `@objc` download actions perform the async WebKit point-resolution
    /// hops and logging, then forward each resolved URL into this resolver and
    /// act on the returned decision. Reuses the same classifier instance.
    private lazy var contextDownloadCandidateResolver =
        BrowserContextMenuDownloadCandidateResolver(urlClassifier: downloadURLClassifier)
    private let contextMenuItemClassifier = BrowserContextMenuItemClassifier()
    /// Set-membership predicates over the stable drag wire identifiers, owned in
    /// `CmuxBrowser`. The drag-registration filter and the five
    /// `NSDraggingInfo` overrides below route through this held policy.
    private let internalPaneDragRoutingPolicy = BrowserInternalPaneDragRoutingPolicy()
    /// The context-menu download + image-copy network/save orchestration, owned in
    /// `CmuxBrowser`. The `@objc` action methods resolve the clicked URL from app
    /// capture state, then call this service to fetch/save/copy. App-side state
    /// (cookie store, user agent, referer, downloading-state notification,
    /// native-action fallback, JavaScript URL lookups, debug log) rides in through
    /// the injected `BrowserContextDownloadSeam`.
    private lazy var contextDownloadService = BrowserContextDownloadService(
        urlClassifier: downloadURLClassifier,
        filenameResolver: BrowserDownloadFilenameResolver(),
        seam: BrowserContextDownloadSeam(
            cookieStore: { [weak self] in
                self?.configuration.websiteDataStore.httpCookieStore ?? WKWebsiteDataStore.default().httpCookieStore
            },
            referer: { [weak self] in self?.url?.absoluteString },
            userAgent: { [weak self] in self?.customUserAgent },
            onDownloadStateChanged: { [weak self] downloading in
                self?.onContextMenuDownloadStateChanged?(downloading)
            },
            runFallback: { [weak self] action, target, sender, traceID, reason in
                self?.runContextMenuFallback(
                    action: action,
                    target: target,
                    sender: sender,
                    traceID: traceID,
                    reason: reason
                )
            },
            findImageURLAtPoint: { [weak self] point, completion in
                guard let self else { return completion(nil) }
                self.findImageURLAtPoint(point, completion: completion)
            },
            findLinkURLAtPoint: { [weak self] point, completion in
                guard let self else { return completion(nil) }
                self.findLinkURLAtPoint(point, completion: completion)
            },
            log: { [weak self] message in
                self?.debugContextDownload(message)
            }
        )
    )
    private static let browserFocusModeContextMenuItemIdentifier =
        NSUserInterfaceItemIdentifier("cmux.browserFocusMode.toggle")
    private static var pasteAsPlainTextFocusHandlerInstalledKey: UInt8 = 0
    // Paste-as-plain-text JS sources + the focus message-handler name moved to
    // `CmuxBrowser/Pasteboard/BrowserPasteAsPlainTextScript.swift`; the app keeps
    // the message-handler subclass, the install, and the @MainActor bridge below.
    private final class PasteAsPlainTextFocusMessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let webView = message.webView as? CmuxWebView else {
                return
            }
            guard let body = message.body as? [String: Any],
                  let canPaste = body["canPaste"] as? Bool else {
                return
            }
            Task { @MainActor [weak webView] in
                webView?.updatePasteAsPlainTextTargetAvailable(canPaste)
            }
        }
    }

    private static let sharedPasteAsPlainTextFocusMessageHandler = PasteAsPlainTextFocusMessageHandler()

    /// Answers whether the navigating web view had a recent local middle-click,
    /// routing through that view's held `BrowserMiddleClickIntentTracker`. The
    /// navigation/UI delegates call this with the web view they are navigating, so
    /// the per-view tracker matches exactly the view that recorded the click.
    static func hasRecentMiddleClickIntent(for webView: WKWebView) -> Bool {
        guard let webView = webView as? CmuxWebView else { return false }
        return webView.middleClickIntentTracker.hasRecentIntent(for: webView)
    }

    private final class ContextMenuFallbackBox: NSObject {
        weak var target: AnyObject?
        let action: Selector?

        init(target: AnyObject?, action: Selector?) {
            self.target = target
            self.action = action
        }
    }

    private static var contextMenuFallbackKey: UInt8 = 0
    var onContextMenuDownloadStateChanged: ((Bool) -> Void)?
    /// Called when "Open Link in New Tab" context menu is selected.
    /// Bypasses createWebViewWith so the link opens as a tab, not a popup.
    var onContextMenuOpenLinkInNewTab: ((URL) -> Void)?
    /// Called for physical mouse back/forward buttons so BrowserPanel can use
    /// its restored-session history fallback instead of raw WKWebView history.
    var onMouseBackButton: (() -> Void)?
    var onMouseForwardButton: (() -> Void)?
    var contextMenuLinkURLProvider: ((CmuxWebView, NSPoint, @escaping (URL?) -> Void) -> Void)?
    var contextMenuDefaultBrowserOpener: ((URL) -> Bool)?
    var contextMenuCanMoveTabToNewWorkspace: (() -> Bool)?; var contextMenuMoveTabToNewWorkspace: (() -> Bool)?
    /// Guard against background panes stealing first responder (e.g. page autofocus).
    /// BrowserPanelView updates this as pane focus state changes.
    var allowsFirstResponderAcquisition: Bool = true
    private var pointerFocusAllowanceDepth: Int = 0
    private var pasteAsPlainTextTargetAvailable = false
    private var lastPasteAsPlainTextPerformKeyEventTimestamp: TimeInterval?
    var allowsFirstResponderAcquisitionEffective: Bool {
        allowsFirstResponderAcquisition || pointerFocusAllowanceDepth > 0
    }
    var debugPointerFocusAllowanceDepth: Int { pointerFocusAllowanceDepth }

    init(
        frame: NSRect,
        configuration: WKWebViewConfiguration,
        middleClickIntentTracker: BrowserMiddleClickIntentTracker = BrowserMiddleClickIntentTracker()
    ) {
        self.middleClickIntentTracker = middleClickIntentTracker
        super.init(frame: frame, configuration: configuration)
        installPasteAsPlainTextFocusTracking()
        installScriptedDownloadInterception()
        installContextMenuLinkCapture()
    }
    override convenience init(frame: NSRect, configuration: WKWebViewConfiguration) {
        self.init(frame: frame, configuration: configuration, middleClickIntentTracker: BrowserMiddleClickIntentTracker())
    }
    required init?(coder: NSCoder) {
        self.middleClickIntentTracker = BrowserMiddleClickIntentTracker()
        super.init(coder: coder)
        installPasteAsPlainTextFocusTracking()
        installScriptedDownloadInterception()
        installContextMenuLinkCapture()
    }

    private func installPasteAsPlainTextFocusTracking() {
        let userContentController = configuration.userContentController
        if objc_getAssociatedObject(
            userContentController,
            &Self.pasteAsPlainTextFocusHandlerInstalledKey
        ) != nil {
            return
        }

        userContentController.add(
            Self.sharedPasteAsPlainTextFocusMessageHandler,
            name: BrowserPasteAsPlainTextScript.focusMessageHandlerName
        )
        objc_setAssociatedObject(
            userContentController,
            &Self.pasteAsPlainTextFocusHandlerInstalledKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private func updatePasteAsPlainTextTargetAvailable(_ available: Bool) {
        guard pasteAsPlainTextTargetAvailable != available else { return }
        pasteAsPlainTextTargetAvailable = available
#if DEBUG
        cmuxDebugLog(
            "browser.pasteAsPlainText.target " +
            "web=\(ObjectIdentifier(self)) available=\(available ? 1 : 0)"
        )
#endif
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func becomeFirstResponder() -> Bool {
        guard allowsFirstResponderAcquisitionEffective else {
#if DEBUG
            let eventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
            cmuxDebugLog(
                "browser.focus.blockedBecome web=\(ObjectIdentifier(self)) " +
                "policy=\(allowsFirstResponderAcquisition ? 1 : 0) " +
                "pointerDepth=\(pointerFocusAllowanceDepth) eventType=\(eventType)"
            )
#endif
            return false
        }
        let result = super.becomeFirstResponder()
        if result {
            NotificationCenter.default.post(
                name: .browserDidBecomeFirstResponderWebView,
                object: self,
                userInfo: Notification.browserFirstResponderUserInfo(
                    pointerInitiated: pointerFocusAllowanceDepth > 0
                )
            )
        }
#if DEBUG
        let eventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
        cmuxDebugLog(
            "browser.focus.become web=\(ObjectIdentifier(self)) result=\(result ? 1 : 0) " +
            "policy=\(allowsFirstResponderAcquisition ? 1 : 0) " +
            "pointerDepth=\(pointerFocusAllowanceDepth) eventType=\(eventType)"
        )
#endif
        return result
    }

    /// Temporarily permits focus acquisition for explicit pointer-driven interactions
    /// (mouse click into this webview) while keeping background autofocus blocked.
    func withPointerFocusAllowance<T>(_ body: () -> T) -> T {
        pointerFocusAllowanceDepth += 1
#if DEBUG
        cmuxDebugLog(
            "browser.focus.pointerAllowance.enter web=\(ObjectIdentifier(self)) " +
            "depth=\(pointerFocusAllowanceDepth)"
        )
#endif
        defer {
            pointerFocusAllowanceDepth = max(0, pointerFocusAllowanceDepth - 1)
#if DEBUG
            cmuxDebugLog(
                "browser.focus.pointerAllowance.exit web=\(ObjectIdentifier(self)) " +
                "depth=\(pointerFocusAllowanceDepth)"
            )
#endif
        }
        return body()
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
        let evaluation = evaluateJavaScriptSynchronously(
            BrowserPasteAsPlainTextScript.pageCanAcceptPlainTextPreflightSource
        )
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
                    forwardKeyDownToWebKit(event)
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

        if BrowserPasteAsPlainTextKeyCommand().matches(event: event) {
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
                forwardKeyDownToWebKit(event)
                return
            case .consume:
#if DEBUG
                route = "focusModeExit"
#endif
                return
            }
        }

        if BrowserPasteAsPlainTextKeyCommand().matches(event: event) {
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
            forwardKeyDownToWebKit(event)
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

        forwardKeyDownToWebKit(event)
    }

    // MARK: - Focus on click

    // The SwiftUI Color.clear overlay (.onTapGesture) that focuses panes can't receive
    // clicks when a WKWebView is underneath — AppKit delivers the click to the deepest
    // NSView (WKWebView), not to sibling SwiftUI overlays. Notify the panel system so
    // bonsplit focus tracks which pane the user clicked in.
    override func mouseDown(with event: NSEvent) {
#if DEBUG
        let windowNumber = window?.windowNumber ?? -1
        let firstResponderType = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        cmuxDebugLog(
            "browser.focus.mouseDown web=\(ObjectIdentifier(self)) " +
            "policy=\(allowsFirstResponderAcquisition ? 1 : 0) " +
            "pointerDepth=\(pointerFocusAllowanceDepth) win=\(windowNumber) fr=\(firstResponderType)"
        )
#endif
        // Ctrl-click opens the context menu like a right-click; scope the
        // captured link to this click so a previous click's link can't pair
        // with the menu this click opens.
        if event.modifierFlags.contains(.control) {
            contextMenuCapturedLink = nil
        }
        performBrowserClickFocusHandoff {
            super.mouseDown(with: event)
        }
    }

    // Each physical right-click starts a fresh capture lifecycle: WebKit
    // dispatches the DOM contextmenu event (which refills the capture) after
    // this and before willOpenMenu, so clearing here guarantees the menu can
    // only ever pair with a link captured by this exact click.
    override func rightMouseDown(with event: NSEvent) {
        contextMenuCapturedLink = nil
        super.rightMouseDown(with: event)
    }

    private func performBrowserClickFocusHandoff(_ action: () -> Void) {
        NotificationCenter.default.post(name: .webViewDidReceiveClick, object: self)
        withPointerFocusAllowance(action)
    }

    // MARK: - Mouse back/forward buttons

    private func handleMouseNavigationButton(_ event: NSEvent) -> Bool {
        // Button 3 = back, button 4 = forward (multi-button mice like Logitech).
        // Consume the event so WebKit/page content does not also handle it.
        switch event.buttonNumber {
        case 3:
#if DEBUG
            cmuxDebugLog("browser.mouse.navigation web=\(ObjectIdentifier(self)) kind=back canGoBack=\(canGoBack ? 1 : 0)")
#endif
            if let onMouseBackButton {
                onMouseBackButton()
            } else {
                goBack()
            }
            return true
        case 4:
#if DEBUG
            cmuxDebugLog("browser.mouse.navigation web=\(ObjectIdentifier(self)) kind=forward canGoForward=\(canGoForward ? 1 : 0)")
#endif
            if let onMouseForwardButton {
                onMouseForwardButton()
            } else {
                goForward()
            }
            return true
        default:
            return false
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            middleClickIntentTracker.record(for: self)
        }
#if DEBUG
        let point = convert(event.locationInWindow, from: nil)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        cmuxDebugLog(
            "browser.mouse.otherDown web=\(ObjectIdentifier(self)) button=\(event.buttonNumber) " +
            "clicks=\(event.clickCount) mods=\(mods) point=(\(Int(point.x)),\(Int(point.y)))"
        )
#endif
        if event.buttonNumber == 3 || event.buttonNumber == 4 {
            performBrowserClickFocusHandoff {
                _ = window?.makeFirstResponder(self)
            }
        }
        if handleMouseNavigationButton(event) {
            return
        }
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            middleClickIntentTracker.record(for: self)
        }
#if DEBUG
        let point = convert(event.locationInWindow, from: nil)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        cmuxDebugLog(
            "browser.mouse.otherUp web=\(ObjectIdentifier(self)) button=\(event.buttonNumber) " +
            "clicks=\(event.clickCount) mods=\(mods) point=(\(Int(point.x)),\(Int(point.y)))"
        )
#endif
        if event.buttonNumber == 3 || event.buttonNumber == 4 {
            return
        }
        super.otherMouseUp(with: event)
    }

    // MARK: - Context menu download support

    /// The last context-menu point in view coordinates.
    private var lastContextMenuPoint: NSPoint = .zero
    /// Link reported by the contextmenu capture hook for the most recent
    /// right-click (`url` is nil when the click was not on a link). The type
    /// and its lifecycle live in `CmuxWebView+ContextMenuLinkCapture.swift`;
    /// only the stored property has to live in the class body.
    var contextMenuCapturedLink: ContextMenuCapturedLink?
    /// Uptime at which the current context menu opened, used to pair the menu
    /// with the contextmenu capture report from the same right-click.
    var lastContextMenuOpenUptime: TimeInterval?
    /// `NSEvent.timestamp` of the event that opened the current context menu
    /// (same uptime clock as `ProcessInfo.systemUptime`). The DOM contextmenu
    /// capture for that menu is always reported after this instant, so a
    /// capture older than it belongs to a previous click and must not pair
    /// with this menu, even on menu-open paths that never saw a mouse event.
    var lastContextMenuOpenEventTimestamp: TimeInterval?
    /// Saved native WebKit action for "Download Image".
    private var fallbackDownloadImageTarget: AnyObject?
    private var fallbackDownloadImageAction: Selector?
    /// Saved native WebKit action for "Copy Image".
    private var fallbackCopyImageTarget: AnyObject?
    private var fallbackCopyImageAction: Selector?
    /// Saved native WebKit action for "Download Linked File".
    private var fallbackDownloadLinkedFileTarget: AnyObject?
    private var fallbackDownloadLinkedFileAction: Selector?

    static func makeContextDownloadTraceID(prefix: String) -> String {
#if DEBUG
        return "\(prefix)-\(UUID().uuidString.prefix(8))"
#else
        return prefix
#endif
    }

    func debugContextDownload(_ message: @autoclosure () -> String) {
#if DEBUG
        cmuxDebugLog(ContextDownloadDebugRedactor().redact(message()))
#endif
    }

    private func debugLogContextMenuDownloadCandidate(_ item: NSMenuItem, index: Int) {
        let identifier = item.identifier?.rawValue ?? "nil"
        let title = item.title
        let actionName = contextMenuItemClassifier.selectorName(item.action)
        let idToken = contextMenuItemClassifier.normalizedContextMenuToken(identifier)
        let titleToken = contextMenuItemClassifier.normalizedContextMenuToken(title)
        let actionToken = contextMenuItemClassifier.normalizedContextMenuToken(actionName)
        guard idToken.contains("download")
            || titleToken.contains("download")
            || actionToken.contains("download") else {
            return
        }
        debugContextDownload(
            "browser.ctxdl.menu item index=\(index) id=\(identifier) title=\(title) action=\(actionName)"
        )
    }

    private func isOurContextMenuAction(target: AnyObject?, action: Selector?) -> Bool {
        guard target === self else { return false }
        if action == #selector(contextMenuToggleBrowserFocusMode(_:)) {
            return true
        }
        if action == #selector(contextMenuCopyImage(_:)) {
            return true
        }
        return action == #selector(contextMenuDownloadImage(_:))
            || action == #selector(contextMenuDownloadLinkedFile(_:))
    }

    private func normalizedLinkedDownloadURL(_ url: URL) -> URL {
        contextDownloadService.normalizedLinkedDownloadURL(url)
    }

    private func captureFallbackForMenuItemIfNeeded(_ item: NSMenuItem) {
        let target = item.target as AnyObject?
        let action = item.action
        if isOurContextMenuAction(target: target, action: action) {
            return
        }
        let box = ContextMenuFallbackBox(target: target, action: action)
        objc_setAssociatedObject(
            item,
            &Self.contextMenuFallbackKey,
            box,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private func fallbackFromSender(
        _ sender: Any?,
        defaultAction: Selector?,
        defaultTarget: AnyObject?
    ) -> (action: Selector?, target: AnyObject?) {
        if let item = sender as? NSMenuItem,
           let box = objc_getAssociatedObject(item, &Self.contextMenuFallbackKey) as? ContextMenuFallbackBox {
            return (box.action, box.target)
        }
        return (defaultAction, defaultTarget)
    }

    /// Resolve the topmost image URL near a point, accounting for overlay layers.
    private func findImageURLAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
        let cssPoint = cssViewportPoint(for: point)
        let js = BrowserContextMenuImageScript.resolveImageURL(at: cssPoint).source
        evaluateJavaScript(js) { result, _ in
            guard let src = result as? String, !src.isEmpty,
                  let url = URL(string: src) else {
                completion(nil)
                return
            }
            completion(url)
        }
    }

    private func debugInspectElementsAtPoint(_ point: NSPoint, traceID: String, kind: String) {
#if DEBUG
        let cssPoint = cssViewportPoint(for: point)
        let js = BrowserContextMenuImageScript.debugInspectElements(at: cssPoint).source
        evaluateJavaScript(js) { [weak self] result, _ in
            guard let self,
                  let payload = result as? String,
                  !payload.isEmpty else { return }
            self.debugContextDownload(
                "browser.ctxdl.inspect trace=\(traceID) kind=\(kind) payload=\(payload)"
            )
        }
#endif
    }

    private func appendBrowserFocusModeContextMenuItem(to menu: NSMenu) {
        let state = AppDelegate.shared?.browserFocusModeContextMenuState(for: self) ?? (isActive: false, canToggle: false)
        guard state.isActive || state.canToggle else { return }

        let title = state.isActive
            ? String(localized: "browser.focusMode.context.exit", defaultValue: "Exit Browser Focus Mode")
            : String(localized: "browser.focusMode.context.enter", defaultValue: "Enter Browser Focus Mode")
        if let item = menu.items.first(where: { $0.identifier == Self.browserFocusModeContextMenuItemIdentifier }) {
            item.title = title
            item.target = self
            item.action = #selector(contextMenuToggleBrowserFocusMode(_:))
            item.state = state.isActive ? NSControl.StateValue.on : NSControl.StateValue.off
            return
        }

        if menu.items.last?.isSeparatorItem == false {
            menu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: title,
            action: #selector(contextMenuToggleBrowserFocusMode(_:)),
            keyEquivalent: ""
        )
        item.identifier = Self.browserFocusModeContextMenuItemIdentifier
        item.target = self
        item.state = state.isActive ? NSControl.StateValue.on : NSControl.StateValue.off
        menu.addItem(item)
    }

    private func runContextMenuFallback(
        action: Selector?,
        target: AnyObject?,
        sender: Any?,
        traceID: String? = nil,
        reason: String? = nil
    ) {
        let trace = traceID ?? "unknown"
        guard let action else {
            debugContextDownload(
                "browser.ctxdl.fallback trace=\(trace) reason=\(reason ?? "none") action=nil target=\(String(describing: target))"
            )
            return
        }
        // Guard against accidental self-recursion if fallback gets overwritten.
        if isOurContextMenuAction(target: target, action: action) {
            debugContextDownload(
                "browser.ctxdl.fallback trace=\(trace) reason=\(reason ?? "none") skipped=recursive action=\(contextMenuItemClassifier.selectorName(action))"
            )
            return
        }
        let dispatched = NSApp.sendAction(action, to: target, from: sender)
        debugContextDownload(
            "browser.ctxdl.fallback trace=\(trace) reason=\(reason ?? "none") dispatched=\(dispatched ? 1 : 0) action=\(contextMenuItemClassifier.selectorName(action)) target=\(String(describing: target))"
        )
    }

    private func notifyContextMenuDownloadState(_ downloading: Bool) {
        contextDownloadService.notifyContextMenuDownloadState(downloading)
    }

    func downloadURLViaSession(
        _ url: URL,
        suggestedFilename: String?,
        sender: Any?,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?,
        traceID: String
    ) {
        contextDownloadService.downloadURLViaSession(
            url,
            suggestedFilename: suggestedFilename,
            sender: sender,
            fallbackAction: fallbackAction,
            fallbackTarget: fallbackTarget,
            traceID: traceID
        )
    }

    private func startContextMenuDownload(
        _ url: URL,
        sender: Any?,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?,
        traceID: String
    ) {
        contextDownloadService.startContextMenuDownload(
            url,
            sender: sender,
            fallbackAction: fallbackAction,
            fallbackTarget: fallbackTarget,
            traceID: traceID
        )
    }

    private func inferredImageMIMEType(from url: URL) -> String? {
        contextDownloadService.inferredImageMIMEType(from: url)
    }

    private func resolveContextMenuCopyImageSourceURL(
        at point: NSPoint,
        completion: @escaping (URL?) -> Void
    ) {
        contextDownloadService.resolveContextMenuCopyImageSourceURL(at: point, completion: completion)
    }

    private func fetchContextMenuImageCopyPayload(
        from sourceURL: URL,
        traceID: String,
        completion: @escaping (BrowserImageCopyPasteboardPayload?) -> Void
    ) {
        contextDownloadService.fetchContextMenuImageCopyPayload(
            from: sourceURL,
            traceID: traceID,
            completion: completion
        )
    }

    private func writeContextMenuImageCopyPayload(
        _ payload: BrowserImageCopyPasteboardPayload,
        expectedPasteboardChangeCount: Int,
        traceID: String
    ) -> (wrote: Bool, shouldFallback: Bool) {
        contextDownloadService.writeContextMenuImageCopyPayload(
            payload,
            expectedPasteboardChangeCount: expectedPasteboardChangeCount,
            traceID: traceID
        )
    }

    // MARK: - Drag-and-drop passthrough

    // WKWebView inherently calls registerForDraggedTypes with public.text (and others).
    // Bonsplit tab drags use NSString (public.utf8-plain-text) which conforms to public.text,
    // so AppKit's view-hierarchy-based drag routing delivers the session to WKWebView instead
    // of SwiftUI's sibling .onDrop overlays. Rejecting in draggingEntered doesn't help because
    // AppKit only bubbles up through superviews, not siblings.
    //
    // Fix: filter out text-based types that conflict with bonsplit tab drags, but keep
    // file URL types so Finder file drops and HTML drag-and-drop work. The blocked-type
    // set and the internal-pane-drag predicate live in `BrowserInternalPaneDragRoutingPolicy`
    // (held as `internalPaneDragRoutingPolicy`); these overrides route through it.

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        let blocked = internalPaneDragRoutingPolicy.blockedDragTypes
        let filtered = newTypes.filter { !blocked.contains($0) }
        if !filtered.isEmpty {
            super.registerForDraggedTypes(filtered)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !internalPaneDragRoutingPolicy.shouldRejectInternalPaneDrag(sender.draggingPasteboard.types) else { return [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !internalPaneDragRoutingPolicy.shouldRejectInternalPaneDrag(sender.draggingPasteboard.types) else { return [] }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard !internalPaneDragRoutingPolicy.shouldRejectInternalPaneDrag(sender.draggingPasteboard.types) else { return false }
        return super.performDragOperation(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard !internalPaneDragRoutingPolicy.shouldRejectInternalPaneDrag(sender.draggingPasteboard.types) else { return false }
        return super.prepareForDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        guard !internalPaneDragRoutingPolicy.shouldRejectInternalPaneDrag(sender?.draggingPasteboard.types) else { return }
        super.concludeDragOperation(sender)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        lastContextMenuPoint = convert(event.locationInWindow, from: nil)
        lastContextMenuOpenUptime = ProcessInfo.processInfo.systemUptime
        lastContextMenuOpenEventTimestamp = event.timestamp
        debugContextDownload(
            "browser.ctxdl.menu open itemCount=\(menu.items.count) point=(\(Int(lastContextMenuPoint.x)),\(Int(lastContextMenuPoint.y)))"
        )
        var openLinkInsertionIndex: Int?
        var hasDefaultBrowserOpenLinkItem = false

        for (index, item) in menu.items.enumerated() {
            debugLogContextMenuDownloadCandidate(item, index: index)
            if !hasDefaultBrowserOpenLinkItem,
               (item.action == #selector(contextMenuOpenLinkInDefaultBrowser(_:))
                || item.title == String(localized: "browser.contextMenu.openLinkInDefaultBrowser", defaultValue: "Open Link in Default Browser")) {
                hasDefaultBrowserOpenLinkItem = true
            }

            if openLinkInsertionIndex == nil,
               (item.identifier?.rawValue == "WKMenuItemIdentifierOpenLink"
                || item.title == "Open Link") {
                openLinkInsertionIndex = index + 1
            }

            // Retarget "Open Link in New Window" to open as a tab, not a popup.
            // Without this, WebKit's default action calls createWebViewWith with
            // navigationType .other, which our classifier would treat as a scripted
            // popup request.
            if item.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow"
                || item.title.contains("Open Link in New Window") {
                item.title = String(localized: "browser.contextMenu.openLinkInNewTab", defaultValue: "Open Link in New Tab")
                item.target = self
                item.action = #selector(contextMenuOpenLinkInNewTab(_:))
            }

            if contextMenuItemClassifier.isDownloadImageMenuItem(item) {
                debugContextDownload(
                    "browser.ctxdl.menu hook kind=image index=\(index) id=\(item.identifier?.rawValue ?? "nil") title=\(item.title) action=\(contextMenuItemClassifier.selectorName(item.action))"
                )
                captureFallbackForMenuItemIfNeeded(item)
                // Keep global fallback as a secondary safety net.
                if let box = objc_getAssociatedObject(item, &Self.contextMenuFallbackKey) as? ContextMenuFallbackBox {
                    fallbackDownloadImageTarget = box.target
                    fallbackDownloadImageAction = box.action
                } else if !isOurContextMenuAction(target: item.target as AnyObject?, action: item.action) {
                    fallbackDownloadImageTarget = item.target as AnyObject?
                    fallbackDownloadImageAction = item.action
                }
                item.target = self
                item.action = #selector(contextMenuDownloadImage(_:))
            }

            if contextMenuItemClassifier.isCopyImageMenuItem(item) {
                debugContextDownload(
                    "browser.ctxcopy.menu hook kind=image index=\(index) id=\(item.identifier?.rawValue ?? "nil") title=\(item.title) action=\(contextMenuItemClassifier.selectorName(item.action))"
                )
                captureFallbackForMenuItemIfNeeded(item)
                if let box = objc_getAssociatedObject(item, &Self.contextMenuFallbackKey) as? ContextMenuFallbackBox {
                    fallbackCopyImageTarget = box.target
                    fallbackCopyImageAction = box.action
                } else if !isOurContextMenuAction(target: item.target as AnyObject?, action: item.action) {
                    fallbackCopyImageTarget = item.target as AnyObject?
                    fallbackCopyImageAction = item.action
                }
                item.target = self
                item.action = #selector(contextMenuCopyImage(_:))
            }

            if contextMenuItemClassifier.isDownloadLinkedFileMenuItem(item) {
                debugContextDownload(
                    "browser.ctxdl.menu hook kind=linked index=\(index) id=\(item.identifier?.rawValue ?? "nil") title=\(item.title) action=\(contextMenuItemClassifier.selectorName(item.action))"
                )
                captureFallbackForMenuItemIfNeeded(item)
                // Keep global fallback as a secondary safety net.
                if let box = objc_getAssociatedObject(item, &Self.contextMenuFallbackKey) as? ContextMenuFallbackBox {
                    fallbackDownloadLinkedFileTarget = box.target
                    fallbackDownloadLinkedFileAction = box.action
                } else if !isOurContextMenuAction(target: item.target as AnyObject?, action: item.action) {
                    fallbackDownloadLinkedFileTarget = item.target as AnyObject?
                    fallbackDownloadLinkedFileAction = item.action
                }
                item.target = self
                item.action = #selector(contextMenuDownloadLinkedFile(_:))
            }
        }

        if let openLinkInsertionIndex, !hasDefaultBrowserOpenLinkItem {
            let item = NSMenuItem(
                title: String(localized: "browser.contextMenu.openLinkInDefaultBrowser", defaultValue: "Open Link in Default Browser"),
                action: #selector(contextMenuOpenLinkInDefaultBrowser(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.insertItem(item, at: min(openLinkInsertionIndex, menu.items.count))
        }
        appendScreenshotContextMenuItems(to: menu)
        appendMoveTabToNewWorkspaceContextMenuItem(to: menu)
        appendBrowserFocusModeContextMenuItem(to: menu)
    }

    @objc private func contextMenuToggleBrowserFocusMode(_ sender: Any?) {
        _ = sender
        if AppDelegate.shared?.toggleBrowserFocusModeFromContextMenu(for: self) != true {
            NSSound.beep()
        }
    }

    @objc private func contextMenuOpenLinkInDefaultBrowser(_ sender: Any?) {
        _ = sender
        let point = lastContextMenuPoint
        resolveContextMenuLinkURL(at: point) { [weak self] url in
            guard let self, let url, self.canOpenInDefaultBrowser(url) else { return }
            self.openContextMenuLinkInDefaultBrowser(url)
        }
    }

    @objc private func contextMenuOpenLinkInNewTab(_ sender: Any?) {
        let point = lastContextMenuPoint
        resolveContextMenuLinkURL(at: point) { [weak self] url in
            guard let self, let url else { return }
            self.onContextMenuOpenLinkInNewTab?(url)
        }
    }

    @objc private func contextMenuCopyImage(_ sender: Any?) {
        let traceID = Self.makeContextDownloadTraceID(prefix: "cpy")
        let point = lastContextMenuPoint
        let pasteboardChangeCount = NSPasteboard.general.changeCount
        debugContextDownload(
            "browser.ctxcopy.click trace=\(traceID) point=(\(Int(point.x)),\(Int(point.y)))"
        )

        let fallback = fallbackFromSender(
            sender,
            defaultAction: fallbackCopyImageAction,
            defaultTarget: fallbackCopyImageTarget
        )
        debugContextDownload(
            "browser.ctxcopy.click trace=\(traceID) fallback action=\(contextMenuItemClassifier.selectorName(fallback.action)) target=\(String(describing: fallback.target))"
        )

        resolveContextMenuCopyImageSourceURL(at: point) { [weak self] sourceURL in
            guard let self else { return }
            guard let sourceURL else {
                self.debugContextDownload(
                    "browser.ctxcopy.resolve trace=\(traceID) stage=noSourceURL"
                )
                self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "copy")
                self.runContextMenuFallback(
                    action: fallback.action,
                    target: fallback.target,
                    sender: sender,
                    traceID: traceID,
                    reason: "no_copy_image_url"
                )
                return
            }

            self.debugContextDownload(
                "browser.ctxcopy.resolve trace=\(traceID) stage=resolved url=\(sourceURL.absoluteString)"
            )
            self.fetchContextMenuImageCopyPayload(from: sourceURL, traceID: traceID) { payload in
                guard let payload else {
                    self.debugContextDownload(
                        "browser.ctxcopy.resolve trace=\(traceID) stage=noPayload"
                    )
                    self.runContextMenuFallback(
                        action: fallback.action,
                        target: fallback.target,
                        sender: sender,
                        traceID: traceID,
                        reason: "copy_image_fetch_failed"
                    )
                    return
                }

                let writeResult = self.writeContextMenuImageCopyPayload(
                    payload,
                    expectedPasteboardChangeCount: pasteboardChangeCount,
                    traceID: traceID
                )
                if writeResult.wrote {
                    return
                }
                if !writeResult.shouldFallback {
                    return
                }

                self.runContextMenuFallback(
                    action: fallback.action,
                    target: fallback.target,
                    sender: sender,
                    traceID: traceID,
                    reason: "copy_image_write_failed"
                )
            }
        }
    }

    @objc private func contextMenuDownloadImage(_ sender: Any?) {
        let traceID = Self.makeContextDownloadTraceID(prefix: "img")
        let point = lastContextMenuPoint
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) kind=image point=(\(Int(point.x)),\(Int(point.y)))"
        )
        let fallback = fallbackFromSender(
            sender,
            defaultAction: fallbackDownloadImageAction,
            defaultTarget: fallbackDownloadImageTarget
        )
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) fallback action=\(contextMenuItemClassifier.selectorName(fallback.action)) target=\(String(describing: fallback.target))"
        )
        findImageURLAtPoint(point) { [weak self] url in
            guard let self else { return }
            self.debugContextDownload(
                "browser.ctxdl.resolve trace=\(traceID) kind=image imageURL=\(url?.absoluteString ?? "nil")"
            )
            var dataImageURL: URL?
            var weakImageURL: URL?
            switch self.contextDownloadCandidateResolver.classifyPrimaryImageCandidate(url) {
            case .download(let normalized):
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedImageURL=\(normalized.absoluteString)"
                )
                self.startContextMenuDownload(
                    normalized,
                    sender: sender,
                    fallbackAction: fallback.action,
                    fallbackTarget: fallback.target,
                    traceID: traceID
                )
                return
            case .holdDataImage(let dataURL):
                dataImageURL = dataURL
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image dataURLDetected length=\(dataURL.absoluteString.count)"
                )
            case .holdWeakImage(let normalized, let reason):
                weakImageURL = normalized
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedImageURL=\(normalized.absoluteString)"
                )
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image weakCandidateURL=\(normalized.absoluteString) reason=\(reason.rawValue)"
                )
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image rejectedPrimaryImageURL=\(normalized.absoluteString)"
                )
            case .rejectDownloadableNonImage(let normalized):
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedImageURL=\(normalized.absoluteString)"
                )
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image rejectedPrimaryImageURL=\(normalized.absoluteString)"
                )
            case .none:
                break
            }

            // Google Images and similar sites often expose blob:/data: image URLs.
            // If image URL is not directly downloadable, fall back to the nearby link URL.
            self.findLinkURLAtPoint(point) { linkURL in
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackLinkURL=\(linkURL?.absoluteString ?? "nil")"
                )
                if let linkURL {
                    let normalizedLink = self.normalizedLinkedDownloadURL(linkURL)
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedFallbackLinkURL=\(normalizedLink.absoluteString)"
                    )
                }

                let selection = self.contextDownloadCandidateResolver.resolveImageLinkFallback(
                    linkURL: linkURL,
                    heldDataImageURL: dataImageURL,
                    heldWeakImageURL: weakImageURL
                )
                switch selection {
                case .link(let url):
                    self.startContextMenuDownload(
                        url,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                case .dataImage(let url):
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackToDataURL=1"
                    )
                    self.startContextMenuDownload(
                        url,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                case .weakImage(let url):
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackToWeakCandidate=1"
                    )
                    self.startContextMenuDownload(
                        url,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                case .nativeFallback(let reason):
                    self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "image")
                    self.runContextMenuFallback(
                        action: fallback.action,
                        target: fallback.target,
                        sender: sender,
                        traceID: traceID,
                        reason: reason
                    )
                }
            }
        }
    }

    @objc private func contextMenuDownloadLinkedFile(_ sender: Any?) {
        let traceID = Self.makeContextDownloadTraceID(prefix: "lnk")
        let point = lastContextMenuPoint
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) kind=linked point=(\(Int(point.x)),\(Int(point.y)))"
        )
        let fallback = fallbackFromSender(
            sender,
            defaultAction: fallbackDownloadLinkedFileAction,
            defaultTarget: fallbackDownloadLinkedFileTarget
        )
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) fallback action=\(contextMenuItemClassifier.selectorName(fallback.action)) target=\(String(describing: fallback.target))"
        )
        // Shared link resolution with the Open Link actions: prefer the link
        // captured at contextmenu time (correct under page zoom and inside
        // iframes), coordinate hit test only as fallback.
        resolveContextMenuLinkURL(at: point) { [weak self] url in
            guard let self else { return }
            self.debugContextDownload(
                "browser.ctxdl.resolve trace=\(traceID) kind=linked linkURL=\(url?.absoluteString ?? "nil")"
            )
            if let url {
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=linked normalizedLinkURL=\(self.normalizedLinkedDownloadURL(url).absoluteString)"
                )
            }
            switch self.contextDownloadCandidateResolver.classifyLinkedFileCandidate(url) {
            case .download(let normalized):
                self.startContextMenuDownload(
                    normalized,
                    sender: sender,
                    fallbackAction: fallback.action,
                    fallbackTarget: fallback.target,
                    traceID: traceID
                )
                return
            case .tryNextCandidate, .nativeFallback:
                break
            }

            // Fallback 1: image URL under cursor (useful on image-heavy result pages).
            self.findImageURLAtPoint(point) { imageURL in
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackImageURL=\(imageURL?.absoluteString ?? "nil")"
                )
                var dataImageURL: URL?
                switch self.contextDownloadCandidateResolver.classifyLinkedFileImageFallback(imageURL) {
                case .download(let url):
                    self.startContextMenuDownload(
                        url,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                    return
                case .holdDataImage(let dataURL):
                    dataImageURL = dataURL
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackDataURLDetected length=\(dataURL.absoluteString.count)"
                    )
                case .holdWeakImage, .rejectDownloadableNonImage, .none:
                    break
                }

                // Fallback 2: simpler nearest-anchor lookup.
                self.findLinkAtPoint(point) { fallbackURL in
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=linked nearestAnchorURL=\(fallbackURL?.absoluteString ?? "nil")"
                    )
                    if let fallbackURL {
                        self.debugContextDownload(
                            "browser.ctxdl.resolve trace=\(traceID) kind=linked normalizedNearestAnchorURL=\(self.normalizedLinkedDownloadURL(fallbackURL).absoluteString)"
                        )
                    }
                    let selection = self.contextDownloadCandidateResolver.resolveLinkedFileNearestAnchorFallback(
                        nearestAnchorURL: fallbackURL,
                        heldDataImageURL: dataImageURL
                    )
                    switch selection {
                    case .anchor(let url):
                        self.startContextMenuDownload(
                            url,
                            sender: sender,
                            fallbackAction: fallback.action,
                            fallbackTarget: fallback.target,
                            traceID: traceID
                        )
                    case .dataImage(let url):
                        self.debugContextDownload(
                            "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackToDataURL=1"
                        )
                        self.startContextMenuDownload(
                            url,
                            sender: sender,
                            fallbackAction: fallback.action,
                            fallbackTarget: fallback.target,
                            traceID: traceID
                        )
                    case .nativeFallback(let reason):
                        self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "linked")
                        self.runContextMenuFallback(
                            action: fallback.action,
                            target: fallback.target,
                            sender: sender,
                            traceID: traceID,
                            reason: reason
                        )
                    }
                }
            }
        }
    }
}
