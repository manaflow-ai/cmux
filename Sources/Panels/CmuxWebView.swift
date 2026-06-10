import AppKit
import Bonsplit
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

enum BrowserFocusModeKeyDecision: Equatable {
    case inactive
    case forwardToWebView
    case consume
}

/// WKWebView tends to consume some app command equivalents,
/// preventing the app menu/SwiftUI Commands from receiving them. Route app/menu
/// shortcuts first by default, but allow browser content to try browser-local
/// Find-family shortcuts. The configured Find shortcut stays app-owned so cmux can
/// choose browser find or right-sidebar file search from the current focus owner.
final class CmuxWebView: WKWebView {
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
    var pointerFocusAllowanceDepth: Int = 0
    var pasteAsPlainTextTargetAvailable = false
    var lastPasteAsPlainTextPerformKeyEventTimestamp: TimeInterval?
    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        installPasteAsPlainTextFocusTracking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installPasteAsPlainTextFocusTracking()
    }

    /// The last context-menu point in view coordinates.
    var lastContextMenuPoint: NSPoint = .zero
    /// Saved native WebKit action for "Download Image".
    var fallbackDownloadImageTarget: AnyObject?
    var fallbackDownloadImageAction: Selector?
    /// Saved native WebKit action for "Copy Image".
    var fallbackCopyImageTarget: AnyObject?
    var fallbackCopyImageAction: Selector?
    /// Saved native WebKit action for "Download Linked File".
    var fallbackDownloadLinkedFileTarget: AnyObject?
    var fallbackDownloadLinkedFileAction: Selector?

}
