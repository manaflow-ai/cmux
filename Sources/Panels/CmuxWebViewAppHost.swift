import AppKit
import CmuxBrowser
import WebKit

/// The app's ``CmuxWebViewHost``: forwards each call to the current
/// `AppDelegate.shared` (tests swap it per case), keyboard shortcut settings,
/// and the terminal pasteboard service, which is what `CmuxWebView` called
/// directly before it moved into CmuxBrowser.
@MainActor
final class CmuxWebViewAppHost: CmuxWebViewHost {
    func makeDiffViewerNavigationKeyRouter() -> any CmuxWebViewNavigationKeyRouting {
        DiffViewerNavigationKeyRouterAdapter()
    }

    func diffViewerEditableFocusMessageHandler() -> CmuxWebViewScriptMessageHandlerRegistration {
        CmuxWebViewScriptMessageHandlerRegistration(
            handler: DiffViewerEditableFocusMessageHandler.shared,
            name: DiffViewerEditableFocusMessageHandler.name,
            contentWorld: DiffViewerEditableFocusMessageHandler.contentWorld
        )
    }

    func handleBrowserFocusModeKeyEvent(
        _ event: NSEvent,
        webView: CmuxWebView,
        source: String
    ) -> BrowserFocusModeKeyDecision? {
        AppDelegate.shared?.handleBrowserFocusModeKeyEvent(event, webView: webView, source: source)
    }

    func handleBrowserSurfaceKeyEquivalent(_ event: NSEvent) -> Bool? {
        AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event)
    }

    func handleBrowserSurfaceKeyEquivalentBeforeMainMenu(_ event: NSEvent) -> Bool? {
        AppDelegate.shared?.handleBrowserSurfaceKeyEquivalentBeforeMainMenu(event)
    }

    func browserFocusModeContextMenuState(for webView: CmuxWebView) -> (isActive: Bool, canToggle: Bool)? {
        AppDelegate.shared?.browserFocusModeContextMenuState(for: webView)
    }

    func toggleBrowserFocusModeFromContextMenu(for webView: CmuxWebView) -> Bool? {
        AppDelegate.shared?.toggleBrowserFocusModeFromContextMenu(for: webView)
    }

    func appendScreenshotContextMenuItems(to menu: NSMenu, for webView: CmuxWebView) {
        webView.appendScreenshotContextMenuItems(to: menu)
    }

    func routesDocumentEditingShortcutToWebContentFirst(
        _ event: NSEvent,
        responder: NSResponder?
    ) -> Bool {
        shouldRouteBrowserDocumentEditingCommandEquivalentThroughWebContentFirst(event, responder: responder)
    }

    func routesFindShortcutToWebContentFirst(
        _ event: NSEvent,
        responder: NSResponder?,
        owningWebView: CmuxWebView?
    ) -> Bool {
        shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
            event,
            responder: responder,
            owningWebView: owningWebView
        )
    }

    func routesInlineVSCodeCommandPaletteShortcutToWebContentFirst(
        _ event: NSEvent,
        pageURL: URL?
    ) -> Bool {
        shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(event, pageURL: pageURL)
    }

    func isUndoRedoCommandEquivalent(_ event: NSEvent) -> Bool {
        event.cmuxIsUndoRedoCommandEquivalent
    }

    func hasLiveTabTransfer(in pasteboard: NSPasteboard) -> Bool {
        AppDelegate.shared?.liveTabDragCapabilityResolver.resolve(from: pasteboard) != nil
    }

    func hasLiveSidebarTabDrag(in pasteboard: NSPasteboard) -> Bool {
        SidebarTabDragPayload.hasLiveSession(
            in: pasteboard,
            currentSessionId: AppDelegate.shared?.sidebarWorkspaceDragRegistry.currentSessionId
        )
    }

    func paneFirstClickFocusEnabled() -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    func replacePasteboardContents(
        of pasteboard: NSPasteboard,
        with items: [NSPasteboardItem],
        expectedChangeCount: Int
    ) async -> CmuxWebViewPasteboardWriteOutcome {
        let result = await GhosttyApp.terminalPasteboard.replaceContentsAndWait(
            of: pasteboard,
            with: items,
            expectedChangeCount: expectedChangeCount
        )
        return CmuxWebViewPasteboardWriteOutcome(
            conditionNotMet: result.status == .conditionNotMet,
            didWrite: result.didWrite
        )
    }

    func typingTimingStart() -> TimeInterval? {
#if DEBUG
        return CmuxTypingTiming.start()
#else
        return nil
#endif
    }

    func typingTimingLogDuration(
        path: String,
        startedAt: TimeInterval?,
        event: NSEvent?,
        extra: String?
    ) {
#if DEBUG
        CmuxTypingTiming.logDuration(path: path, startedAt: startedAt, event: event, extra: extra)
#endif
    }
}

/// Adapts the app's shortcut-settings-driven ``ViewerNavigationKeyRouter`` to
/// the diff viewer router `CmuxWebView` asks its host for.
@MainActor
private final class DiffViewerNavigationKeyRouterAdapter: CmuxWebViewNavigationKeyRouting {
    private let router = ViewerNavigationKeyRouter(actions: [
        .diffViewerScrollDown, .diffViewerScrollUp,
        .diffViewerScrollHalfPageDown, .diffViewerScrollHalfPageUp,
        .diffViewerScrollDownEmacs, .diffViewerScrollUpEmacs,
        .diffViewerScrollToBottom, .diffViewerScrollToTop,
        .diffViewerOpenFileSearch, .diffViewerNextFile, .diffViewerPreviousFile,
    ])

    func reset() {
        router.reset()
    }

    func handle(
        _ event: NSEvent,
        perform: (CmuxWebViewNavigationKeyAction) -> Void
    ) -> Bool {
        router.handle(event, isAllowed: { action, event in
            AppDelegate.shared?.shortcutWhenClauseAllows(action: action, event: event) ?? true
        }, perform: { action in
            perform(CmuxWebViewNavigationKeyAction(
                rawValue: action.rawValue,
                opensFileSearch: action == .diffViewerOpenFileSearch
            ))
        })
    }
}
