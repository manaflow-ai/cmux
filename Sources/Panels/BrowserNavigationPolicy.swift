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


// MARK: - Navigation policy helpers
func browserPreparedNavigationRequest(_ request: URLRequest) -> URLRequest {
    var preparedRequest = request
    // Match browser behavior for ordinary loads while preserving method/body/headers.
    preparedRequest.cachePolicy = .useProtocolCachePolicy
    return preparedRequest
}

/// Carries the request and one-shot HTTP bypass needed to seed a retargeted tab.
struct BrowserNewTabNavigationSeed {
    let url: URL
    let initialRequest: URLRequest
    let bypassInsecureHTTPHostOnce: String?
}

/// Preserves the original request metadata for a retargeted new-tab navigation.
func browserNewTabNavigationSeed(
    from request: URLRequest,
    bypassInsecureHTTPHostOnce: String? = nil
) -> BrowserNewTabNavigationSeed? {
    guard let url = request.url else { return nil }
    return BrowserNewTabNavigationSeed(
        url: url,
        initialRequest: request,
        bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
    )
}

/// Mirrors the opener's WebKit browsing context for popup windows.
struct BrowserPopupBrowserContext {
    let websiteDataStore: WKWebsiteDataStore
}

private func browserBareHostCandidate(_ lowercasedInput: String) -> String {
    let end = lowercasedInput.firstIndex { character in
        character == ":" || character == "/" || character == "?" || character == "#"
    } ?? lowercasedInput.endIndex
    return String(lowercasedInput[..<end])
}

func resolveBrowserNavigableURL(_ input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !trimmed.contains(" ") else { return nil }

    // Check localhost/loopback before generic URL parsing because
    // URL(string: "localhost:3777") treats "localhost" as a scheme.
    let lower = trimmed.lowercased()
    let bareHost = browserBareHostCandidate(lower)
    if lower.hasPrefix("localhost") ||
        lower.hasPrefix("127.0.0.1") ||
        lower.hasPrefix("[::1]") ||
        (bareHost != ".localhost" && bareHost.hasSuffix(".localhost")) {
        return URL(string: "http://\(trimmed)")
    }

    if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
        if scheme == "http" || scheme == "https" {
            return url
        }
        if scheme == "file", url.isFileURL, url.path.hasPrefix("/") {
            return url
        }
        return nil
    }

    if trimmed.contains(":") || trimmed.contains("/") {
        return URL(string: "https://\(trimmed)")
    }

    if trimmed.contains(".") {
        return URL(string: "https://\(trimmed)")
    }

    return nil
}

func browserNavigationShouldOpenInNewTab(
    navigationType: WKNavigationType,
    modifierFlags: NSEvent.ModifierFlags,
    buttonNumber: Int,
    hasRecentMiddleClickIntent: Bool = false,
    currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type,
    currentEventButtonNumber: Int? = NSApp.currentEvent?.buttonNumber
) -> Bool {
    guard navigationType == .linkActivated || navigationType == .other else {
        return false
    }

    if modifierFlags.contains(.command) {
        return true
    }
    if buttonNumber == 2 {
        return true
    }
    // In some WebKit paths, middle-click arrives as buttonNumber=4.
    // Recover intent when we just observed a local middle-click.
    if buttonNumber == 4, hasRecentMiddleClickIntent {
        return true
    }

    // WebKit can omit buttonNumber for middle-click link activations.
    if let currentEventType,
       (currentEventType == .otherMouseDown || currentEventType == .otherMouseUp),
       currentEventButtonNumber == 2 {
        return true
    }
    return false
}

func browserNavigationShouldCreatePopup(
    navigationType: WKNavigationType,
    modifierFlags: NSEvent.ModifierFlags,
    buttonNumber: Int,
    popupFeaturesWereSpecified: Bool = false,
    hasRecentMiddleClickIntent: Bool = false,
    currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type,
    currentEventButtonNumber: Int? = NSApp.currentEvent?.buttonNumber
) -> Bool {
    let isUserNewTab = browserNavigationShouldOpenInNewTab(
        navigationType: navigationType,
        modifierFlags: modifierFlags,
        buttonNumber: buttonNumber,
        hasRecentMiddleClickIntent: hasRecentMiddleClickIntent,
        currentEventType: currentEventType,
        currentEventButtonNumber: currentEventButtonNumber
    )
    return navigationType == .other && popupFeaturesWereSpecified && !isUserNewTab
}

func browserNavigationShouldFallbackNilTargetToNewTab(
    navigationType: WKNavigationType
) -> Bool {
    // Scripted popups rely on WKUIDelegate.createWebViewWith returning a live
    // web view so window.opener/postMessage remain intact across OAuth flows.
    navigationType != .other
}

private func browserNavigationHasSimpleUserActivation(
    currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type
) -> Bool {
    switch currentEventType {
    case .keyDown, .keyUp, .leftMouseDown, .leftMouseUp:
        return true
    default:
        return false
    }
}

func browserNavigationPopupFeaturesWereSpecified(
    x: NSNumber?,
    y: NSNumber?,
    width: NSNumber?,
    height: NSNumber?,
    menuBarVisibility: NSNumber?,
    statusBarVisibility: NSNumber?,
    toolbarsVisibility: NSNumber?,
    allowsResizing: NSNumber?
) -> Bool {
    x != nil ||
        y != nil ||
        width != nil ||
        height != nil ||
        menuBarVisibility != nil ||
        statusBarVisibility != nil ||
        toolbarsVisibility != nil ||
        allowsResizing != nil
}

func browserNavigationPopupFeaturesWereSpecified(windowFeatures: WKWindowFeatures) -> Bool {
    browserNavigationPopupFeaturesWereSpecified(
        x: windowFeatures.x,
        y: windowFeatures.y,
        width: windowFeatures.width,
        height: windowFeatures.height,
        menuBarVisibility: windowFeatures.menuBarVisibility,
        statusBarVisibility: windowFeatures.statusBarVisibility,
        toolbarsVisibility: windowFeatures.toolbarsVisibility,
        allowsResizing: windowFeatures.allowsResizing
    )
}
// Keep popup retargeting intentionally narrow. Explicit cross-host alias groups
// preserve known first-party search flows without guessing at the public suffix
// list for arbitrary hosted tenants, while same-host scripted popups stay on
// the popup path so opener-dependent browser flows keep working.
private let browserNavigationSimpleUserGesturePopupRetargetHostAliases: [Set<String>] = [
    [
        "bilibili.com",
        "search.bilibili.com",
        "www.bilibili.com",
    ],
]

private func browserNavigationDefaultPort(for scheme: String) -> Int? {
    switch scheme {
    case "http":
        return 80
    case "https":
        return 443
    default:
        return nil
    }
}

private func browserNavigationShouldRetargetSimpleUserGesturePopup(
    requestURL: URL?,
    openerURL: URL?
) -> Bool {
    guard let requestURL,
          let openerURL,
          let requestScheme = requestURL.scheme?.lowercased(), !requestScheme.isEmpty,
          let openerScheme = openerURL.scheme?.lowercased(), !openerScheme.isEmpty,
          requestScheme == openerScheme,
          (requestURL.port ?? browserNavigationDefaultPort(for: requestScheme))
            == (openerURL.port ?? browserNavigationDefaultPort(for: openerScheme)),
          let requestHost = BrowserInsecureHTTPSettings.normalizeHost(requestURL.host ?? ""),
          let openerHost = BrowserInsecureHTTPSettings.normalizeHost(openerURL.host ?? "") else {
        return false
    }
    for aliases in browserNavigationSimpleUserGesturePopupRetargetHostAliases {
        if requestHost != openerHost,
           aliases.contains(requestHost),
           aliases.contains(openerHost) {
            return true
        }
    }
    return false
}

func browserNavigationDebugURL(_ url: URL?) -> String {
    guard let url,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return "nil"
    }
    components.query = nil
    components.fragment = nil
    return components.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "")"
}

func browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
    navigationType: WKNavigationType,
    requestMethod: String?,
    requestURL: URL?,
    openerURL: URL?,
    modifierFlags: NSEvent.ModifierFlags = [],
    buttonNumber: Int = 0,
    hasRecentMiddleClickIntent: Bool = false,
    currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type,
    currentEventButtonNumber: Int? = NSApp.currentEvent?.buttonNumber,
    popupFeaturesWereSpecified: Bool
) -> Bool {
    guard navigationType == .other else {
        return false
    }
    // Some sites use `window.open()` for plain same-site searches triggered by a
    // direct keyboard submit or left-click, without requesting popup chrome or
    // opener-style geometry. Route those to a normal tab while keeping
    // cross-site/OAuth-style popups on the popup path.
    guard browserNavigationHasSimpleUserActivation(currentEventType: currentEventType) else {
        return false
    }
    guard !browserNavigationShouldOpenInNewTab(
        navigationType: navigationType,
        modifierFlags: modifierFlags,
        buttonNumber: buttonNumber,
        hasRecentMiddleClickIntent: hasRecentMiddleClickIntent,
        currentEventType: currentEventType,
        currentEventButtonNumber: currentEventButtonNumber
    ) else {
        return false
    }
    guard (requestMethod ?? "GET").uppercased() == "GET" else {
        return false
    }
    guard !popupFeaturesWereSpecified else {
        return false
    }
    return browserNavigationShouldRetargetSimpleUserGesturePopup(
        requestURL: requestURL,
        openerURL: openerURL
    )
}

