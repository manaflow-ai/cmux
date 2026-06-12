import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif


// MARK: - External navigation routing
private let browserEmbeddedNavigationSchemes: Set<String> = [
    "about",
    "applewebdata",
    "blob",
    "cmux-diff-viewer",
    "data",
    "file",
    "http",
    "https",
    "javascript",
]

func browserShouldOpenURLExternally(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
    return !browserEmbeddedNavigationSchemes.contains(scheme)
}

enum BrowserExternalNavigationAction: Equatable {
    case browserFallback(URL)
    case promptToOpenApp(URL)
}

func browserShouldRouteExternalNavigation(_ url: URL) -> Bool {
    return browserExternalNavigationAction(for: url) != nil
}

func browserIntentFallbackURL(for url: URL) -> URL? {
    guard url.scheme?.lowercased() == "intent" else { return nil }
    guard let intentMarker = url.absoluteString.range(of: "#Intent;") else { return nil }

    let fallbackPrefix = "S.browser_fallback_url="
    let intentBody = url.absoluteString[intentMarker.upperBound...]
    for component in intentBody.split(separator: ";", omittingEmptySubsequences: false) {
        if component == "end" { break }
        guard component.hasPrefix(fallbackPrefix) else { continue }

        let rawFallbackURL = String(component.dropFirst(fallbackPrefix.count))
        guard !rawFallbackURL.isEmpty else { return nil }

        let decodedFallbackURL = rawFallbackURL.removingPercentEncoding ?? rawFallbackURL
        guard let fallbackURL = URL(string: decodedFallbackURL),
              let fallbackScheme = fallbackURL.scheme?.lowercased(),
              fallbackScheme == "http" || fallbackScheme == "https" else {
            return nil
        }
        return fallbackURL
    }

    return nil
}

func browserExternalNavigationAction(for url: URL) -> BrowserExternalNavigationAction? {
    if let fallbackURL = browserIntentFallbackURL(for: url) {
        return .browserFallback(fallbackURL)
    }
    guard browserShouldOpenURLExternally(url) else { return nil }
    return .promptToOpenApp(url)
}

private func browserCopyExternalNavigationURL(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
}

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

typealias BrowserAlertPresenter = (
    _ alert: NSAlert,
    _ webView: WKWebView,
    _ completion: @escaping (NSApplication.ModalResponse) -> Void,
    _ cancel: @escaping () -> Void
) -> Void

func browserPresentAlert(
    _ alert: NSAlert,
    in webView: WKWebView,
    completion: @escaping (NSApplication.ModalResponse) -> Void,
    cancel: @escaping () -> Void = {}
) {
    _ = cancel
    if let window = browserInteractiveModalHostWindow(for: webView) {
        alert.beginSheetModal(for: window, completionHandler: completion)
        return
    }
    completion(alert.runModal())
}

private func browserPresentExternalNavigationPrompt(
    in webView: WKWebView,
    completion: @escaping (Bool) -> Void,
    presentAlert: BrowserAlertPresenter = browserPresentAlert
) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = String(
        localized: "browser.externalOpenPrompt.title",
        defaultValue: "Open External App?"
    )
    alert.informativeText = String(
        localized: "browser.externalOpenPrompt.message",
        defaultValue: "A web page in cmux wants to open a link in another app. You can stay in the browser instead."
    )
    alert.addButton(withTitle: String(
        localized: "browser.externalOpenPrompt.openApp",
        defaultValue: "Open App"
    ))
    alert.addButton(withTitle: String(
        localized: "browser.externalOpenPrompt.stayInBrowser",
        defaultValue: "Stay in Browser"
    ))

    let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
        completion(response == .alertFirstButtonReturn)
    }

    presentAlert(alert, webView, handleResponse) {
        completion(false)
    }
}

private func browserPresentExternalNavigationFailure(
    for url: URL,
    in webView: WKWebView,
    presentAlert: BrowserAlertPresenter = browserPresentAlert
) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(
        localized: "browser.externalOpenFailure.title",
        defaultValue: "Cannot Open Link"
    )
    alert.informativeText = String(
        localized: "browser.externalOpenFailure.message",
        defaultValue: "cmux could not open this link. You can copy it and open it in another app."
    )
    alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
    alert.addButton(withTitle: String(
        localized: "browser.externalOpenFailure.copyLink",
        defaultValue: "Copy Link"
    ))

    let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
        if response == .alertSecondButtonReturn {
            browserCopyExternalNavigationURL(url)
        }
    }

    presentAlert(alert, webView, handleResponse) {}
}

@discardableResult
private func browserOpenExternalNavigationURL(
    _ url: URL,
    source: String,
    webView: WKWebView,
    presentAlert: BrowserAlertPresenter = browserPresentAlert
) -> Bool {
    let opened = NSWorkspace.shared.open(url)
    if !opened {
        browserPresentExternalNavigationFailure(for: url, in: webView, presentAlert: presentAlert)
    }
#if DEBUG
    cmuxDebugLog(
        "browser.navigation.external source=\(source) opened=\(opened ? 1 : 0) " +
        "url=\(browserNavigationDebugURL(url))"
    )
#endif
    return opened
}

@discardableResult
func browserHandleExternalNavigation(
    _ url: URL,
    source: String,
    webView: WKWebView,
    loadFallbackRequest: (URLRequest) -> Void,
    presentAlert: @escaping BrowserAlertPresenter = browserPresentAlert
) -> Bool {
    guard let action = browserExternalNavigationAction(for: url) else { return false }

    switch action {
    case let .browserFallback(fallbackURL):
        let request = URLRequest(url: fallbackURL)
        loadFallbackRequest(request)
#if DEBUG
        cmuxDebugLog(
            "browser.navigation.external source=\(source) opened=1 fallback=1 " +
            "fallbackURL=\(browserNavigationDebugURL(fallbackURL)) url=\(browserNavigationDebugURL(url))"
        )
#endif
        return true

    case let .promptToOpenApp(externalURL):
        browserPresentExternalNavigationPrompt(
            in: webView,
            completion: { shouldOpenApp in
                guard shouldOpenApp else {
#if DEBUG
                    cmuxDebugLog(
                        "browser.navigation.external source=\(source) opened=0 prompt=1 allowed=0 " +
                        "url=\(browserNavigationDebugURL(externalURL))"
                    )
#endif
                    return
                }
                browserOpenExternalNavigationURL(
                    externalURL,
                    source: source,
                    webView: webView,
                    presentAlert: presentAlert
                )
            },
            presentAlert: presentAlert
        )
        return true
    }
}

