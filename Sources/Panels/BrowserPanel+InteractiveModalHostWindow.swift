import AppKit
import WebKit

func browserInteractiveModalHostWindow(_ window: NSWindow?) -> NSWindow? {
    guard let window else { return nil }
    guard window.isVisible else { return nil }
    guard window.alphaValue > 0 else { return nil }
    guard !window.ignoresMouseEvents else { return nil }
    guard !window.isExcludedFromWindowsMenu else { return nil }
    return window
}

func browserInteractiveModalHostWindow(for webView: WKWebView) -> NSWindow? {
    browserInteractiveModalHostWindow(webView.window)
}

func browserFallbackInteractiveModalHostWindow() -> NSWindow? {
    if let keyWindow = browserInteractiveModalHostWindow(NSApp.keyWindow) {
        return keyWindow
    }
    return browserInteractiveModalHostWindow(NSApp.mainWindow)
}
