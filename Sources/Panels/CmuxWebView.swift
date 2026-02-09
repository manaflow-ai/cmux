import AppKit
import WebKit

/// WKWebView tends to consume some Command-key equivalents (e.g. Cmd+N/Cmd+W),
/// preventing the app menu/SwiftUI Commands from receiving them. Route menu
/// key equivalents first so app-level shortcuts continue to work when WebKit is
/// the first responder.
final class CmuxWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let the app menu handle key equivalents first (New Tab, Close Panel, tab switching, etc).
        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

