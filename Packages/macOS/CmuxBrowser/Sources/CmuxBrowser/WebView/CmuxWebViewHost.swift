public import AppKit
public import WebKit

/// App-owned services a ``CmuxWebView`` calls back into.
///
/// `CmuxWebView` lives in this package, but keyboard shortcut routing, browser
/// focus mode, live drag registries, the managed pasteboard, and the diff
/// viewer message bridge are owned by the app target. The app passes a
/// conforming value to ``CmuxWebView/init(frame:configuration:host:)``.
///
/// Optional return values mean "no app context is available"; the web view
/// then uses the same fallback it used when the app delegate was absent.
@MainActor
public protocol CmuxWebViewHost: AnyObject {
    /// Creates the key router for diff viewer navigation shortcuts
    /// (j/k scrolling, file search, next/previous file).
    func makeDiffViewerNavigationKeyRouter() -> any CmuxWebViewNavigationKeyRouting

    /// Registration details for the diff viewer editable-focus message handler,
    /// installed once per user content controller.
    func diffViewerEditableFocusMessageHandler() -> CmuxWebViewScriptMessageHandlerRegistration

    /// Browser focus mode decision for a key event delivered to `webView`,
    /// or `nil` when no app context is available.
    func handleBrowserFocusModeKeyEvent(
        _ event: NSEvent,
        webView: CmuxWebView,
        source: String
    ) -> BrowserFocusModeKeyDecision?

    /// Handles a browser-surface key equivalent, or returns `nil` when no app
    /// context is available.
    func handleBrowserSurfaceKeyEquivalent(_ event: NSEvent) -> Bool?

    /// Handles a browser-surface key equivalent that must win before the main
    /// menu, or returns `nil` when no app context is available.
    func handleBrowserSurfaceKeyEquivalentBeforeMainMenu(_ event: NSEvent) -> Bool?

    /// Browser focus mode state for the web view's context menu item, or `nil`
    /// when no app context is available.
    func browserFocusModeContextMenuState(for webView: CmuxWebView) -> (isActive: Bool, canToggle: Bool)?

    /// Toggles browser focus mode from the context menu, or returns `nil` when
    /// no app context is available.
    func toggleBrowserFocusModeFromContextMenu(for webView: CmuxWebView) -> Bool?

    /// Appends the app's screenshot actions to the web view context menu.
    func appendScreenshotContextMenuItems(to menu: NSMenu, for webView: CmuxWebView)

    /// Whether native document-editing shortcuts (copy, cut, select all,
    /// italic) should reach web content before the main menu.
    func routesDocumentEditingShortcutToWebContentFirst(
        _ event: NSEvent,
        responder: NSResponder?
    ) -> Bool

    /// Whether browser-local Find-family shortcuts should reach web content
    /// before the main menu.
    func routesFindShortcutToWebContentFirst(
        _ event: NSEvent,
        responder: NSResponder?,
        owningWebView: CmuxWebView?
    ) -> Bool

    /// Whether the command palette shortcut belongs to an inline VS Code page.
    func routesInlineVSCodeCommandPaletteShortcutToWebContentFirst(
        _ event: NSEvent,
        pageURL: URL?
    ) -> Bool

    /// Whether `event` is the layout-aware Cmd+Z or Cmd+Shift+Z chord.
    func isUndoRedoCommandEquivalent(_ event: NSEvent) -> Bool

    /// Whether the pasteboard carries a bonsplit tab transfer that a live drag
    /// registry still owns.
    func hasLiveTabTransfer(in pasteboard: NSPasteboard) -> Bool

    /// Whether the pasteboard carries the sidebar drag session that is
    /// currently live.
    func hasLiveSidebarTabDrag(in pasteboard: NSPasteboard) -> Bool

    /// Whether a first click on an unfocused pane should also reach the page.
    func paneFirstClickFocusEnabled() -> Bool

    /// Replaces the pasteboard contents through the app's managed pasteboard
    /// lane and waits for the result.
    func replacePasteboardContents(
        of pasteboard: NSPasteboard,
        with items: [NSPasteboardItem],
        expectedChangeCount: Int
    ) async -> CmuxWebViewPasteboardWriteOutcome

    /// Starts a typing-latency measurement when typing timing logs are enabled.
    func typingTimingStart() -> TimeInterval?

    /// Finishes a typing-latency measurement started by ``typingTimingStart()``.
    func typingTimingLogDuration(
        path: String,
        startedAt: TimeInterval?,
        event: NSEvent?,
        extra: String?
    )
}

/// Routes diff viewer navigation key events to shortcut-bound actions.
@MainActor
public protocol CmuxWebViewNavigationKeyRouting: AnyObject {
    /// Drops any pending chord prefix.
    func reset()

    /// Handles `event`, calling `perform` with the matched action.
    ///
    /// - Returns: `true` when the event was consumed (a matched action or a
    ///   chord prefix).
    func handle(
        _ event: NSEvent,
        perform: (CmuxWebViewNavigationKeyAction) -> Void
    ) -> Bool
}

/// A diff viewer navigation action matched by ``CmuxWebViewNavigationKeyRouting``.
public struct CmuxWebViewNavigationKeyAction: Sendable, Equatable {
    /// The action identifier the diff viewer page understands.
    public let rawValue: String
    /// Whether the action opens the diff viewer's file search field.
    public let opensFileSearch: Bool

    /// Creates a navigation action.
    public init(rawValue: String, opensFileSearch: Bool) {
        self.rawValue = rawValue
        self.opensFileSearch = opensFileSearch
    }
}

/// A script message handler plus the name and content world it is added under.
public struct CmuxWebViewScriptMessageHandlerRegistration {
    /// The handler to add to the user content controller.
    public let handler: any WKScriptMessageHandler
    /// The message handler name the page posts to.
    public let name: String
    /// The content world the handler and its user script run in.
    public let contentWorld: WKContentWorld

    /// Creates a registration.
    public init(handler: any WKScriptMessageHandler, name: String, contentWorld: WKContentWorld) {
        self.handler = handler
        self.name = name
        self.contentWorld = contentWorld
    }
}

/// Result of ``CmuxWebViewHost/replacePasteboardContents(of:with:expectedChangeCount:)``.
public struct CmuxWebViewPasteboardWriteOutcome: Sendable, Equatable {
    /// The pasteboard changed before the write was admitted, so nothing was written.
    public let conditionNotMet: Bool
    /// The new contents were published.
    public let didWrite: Bool

    /// Creates an outcome.
    public init(conditionNotMet: Bool, didWrite: Bool) {
        self.conditionNotMet = conditionNotMet
        self.didWrite = didWrite
    }
}
