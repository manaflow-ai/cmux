import AppKit
import WebKit

/// WKWebView tends to consume some Command-key equivalents (e.g. Cmd+N/Cmd+W),
/// preventing the app menu/SwiftUI Commands from receiving them. Route menu
/// key equivalents first so app-level shortcuts continue to work when WebKit is
/// the first responder.
final class CmuxWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let the app menu handle key equivalents first (New Tab, Close Tab, tab switching, etc).
        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }

        // Handle app-level shortcuts that are not menu-backed (for example split commands).
        // Without this, WebKit can consume Cmd-based shortcuts before the app monitor sees them.
        if AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Some Cmd-based key paths in WebKit don't consistently invoke performKeyEquivalent.
        // Route them through the same app-level shortcut handler as a fallback.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
            return
        }

        super.keyDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        for item in menu.items {
            // Rename "Open Link in New Window" to "Open Link in New Tab".
            // The UIDelegate's createWebViewWith already handles the action
            // by opening the link as a new surface in the same pane.
            if item.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow"
                || item.title.contains("Open Link in New Window") {
                item.title = "Open Link in New Tab"
            }
        }
    }
}
