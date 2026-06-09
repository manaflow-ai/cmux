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

enum BrowserLinkOpenSettings {
    static let openTerminalLinksInCmuxBrowserKey = "browserOpenTerminalLinksInCmuxBrowser"
    static let defaultOpenTerminalLinksInCmuxBrowser: Bool = true

    static let openSidebarPullRequestLinksInCmuxBrowserKey = "browserOpenSidebarPullRequestLinksInCmuxBrowser"
    static let defaultOpenSidebarPullRequestLinksInCmuxBrowser: Bool = true

    static let openSidebarPortLinksInCmuxBrowserKey = "browserOpenSidebarPortLinksInCmuxBrowser"
    static let defaultOpenSidebarPortLinksInCmuxBrowser: Bool = true

    static let interceptTerminalOpenCommandInCmuxBrowserKey = "browserInterceptTerminalOpenCommandInCmuxBrowser"
    static let defaultInterceptTerminalOpenCommandInCmuxBrowser: Bool = true

    static let browserHostWhitelistKey = "browserHostWhitelist"
    static let defaultBrowserHostWhitelist: String = ""
    static let browserExternalOpenPatternsKey = "browserExternalOpenPatterns"
    static let defaultBrowserExternalOpenPatterns: String = ""

    static func openTerminalLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: openTerminalLinksInCmuxBrowserKey) == nil {
            return defaultOpenTerminalLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openTerminalLinksInCmuxBrowserKey)
    }

    static func openSidebarPullRequestLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: openSidebarPullRequestLinksInCmuxBrowserKey) == nil {
            return defaultOpenSidebarPullRequestLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openSidebarPullRequestLinksInCmuxBrowserKey)
    }

    static func openSidebarPortLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: openSidebarPortLinksInCmuxBrowserKey) == nil {
            return defaultOpenSidebarPortLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openSidebarPortLinksInCmuxBrowserKey)
    }

    static func interceptTerminalOpenCommandInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: interceptTerminalOpenCommandInCmuxBrowserKey) != nil {
            return defaults.bool(forKey: interceptTerminalOpenCommandInCmuxBrowserKey)
        }

        // Migrate existing behavior for users who only had the link-click toggle.
        if defaults.object(forKey: openTerminalLinksInCmuxBrowserKey) != nil {
            return defaults.bool(forKey: openTerminalLinksInCmuxBrowserKey)
        }

        return defaultInterceptTerminalOpenCommandInCmuxBrowser
    }

    static func initialInterceptTerminalOpenCommandInCmuxBrowserValue(defaults: UserDefaults = .standard) -> Bool {
        interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults)
    }

    static func hostWhitelist(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.string(forKey: browserHostWhitelistKey) ?? defaultBrowserHostWhitelist
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func externalOpenPatterns(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.string(forKey: browserExternalOpenPatternsKey) ?? defaultBrowserExternalOpenPatterns
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func shouldOpenExternally(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        shouldOpenExternally(url.absoluteString, defaults: defaults)
    }

    static func shouldOpenExternally(_ rawURL: String, defaults: UserDefaults = .standard) -> Bool {
        let target = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return true }

        for rawPattern in externalOpenPatterns(defaults: defaults) {
            guard let (isRegex, value) = parseExternalPattern(rawPattern) else { continue }
            if isRegex {
                guard let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else { continue }
                let range = NSRange(target.startIndex..<target.endIndex, in: target)
                if regex.firstMatch(in: target, options: [], range: range) != nil {
                    return true
                }
            } else if target.range(of: value, options: [.caseInsensitive]) != nil {
                return true
            }
        }

        return false
    }

    /// Check whether a hostname matches the configured whitelist.
    /// Empty whitelist means "allow all" (no filtering).
    /// Supports exact match and wildcard prefix (`*.example.com`).
    static func hostMatchesWhitelist(_ host: String, defaults: UserDefaults = .standard) -> Bool {
        let rawPatterns = hostWhitelist(defaults: defaults)
        if rawPatterns.isEmpty { return true }
        guard let normalizedHost = BrowserInsecureHTTPSettings.normalizeHost(host) else { return false }
        for rawPattern in rawPatterns {
            guard let pattern = normalizeWhitelistPattern(rawPattern) else { continue }
            if hostMatchesPattern(normalizedHost, pattern: pattern) {
                return true
            }
        }
        return false
    }

    private static func normalizeWhitelistPattern(_ rawPattern: String) -> String? {
        let trimmed = rawPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("*.") {
            let suffixRaw = String(trimmed.dropFirst(2))
            guard let suffix = BrowserInsecureHTTPSettings.normalizeHost(suffixRaw) else { return nil }
            return "*.\(suffix)"
        }

        return BrowserInsecureHTTPSettings.normalizeHost(trimmed)
    }

    private static func hostMatchesPattern(_ host: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        return host == pattern
    }

    private static func parseExternalPattern(_ rawPattern: String) -> (isRegex: Bool, value: String)? {
        let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("re:") {
            let regexPattern = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !regexPattern.isEmpty else { return nil }
            return (isRegex: true, value: regexPattern)
        }

        return (isRegex: false, value: trimmed)
    }
}

enum BrowserAvailabilitySettings {
    static let disabledKey = "browserDisabledOverride"
    static let didChangeNotification = Notification.Name("cmux.browserAvailabilityDidChange")
    static let defaultDisabled = false

    static func isDisabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.synchronize()
        if defaults.object(forKey: disabledKey) == nil {
            return defaultDisabled
        }
        return defaults.bool(forKey: disabledKey)
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        !isDisabled(defaults: defaults)
    }

    static func setDisabled(_ disabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(disabled, forKey: disabledKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

enum BrowserInsecureHTTPSettings {
    static let allowlistKey = "browserInsecureHTTPAllowlist"
    static let defaultAllowlistPatterns = [
        "localhost",
        "*.localhost",
        "127.0.0.1",
        "::1",
        "0.0.0.0",
        "*.localtest.me",
    ]
    static let defaultAllowlistText = defaultAllowlistPatterns.joined(separator: "\n")

    static func normalizedAllowlistPatterns(defaults: UserDefaults = .standard) -> [String] {
        normalizedAllowlistPatterns(rawValue: defaults.string(forKey: allowlistKey))
    }

    static func normalizedAllowlistPatterns(rawValue: String?) -> [String] {
        let source: String
        if let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = rawValue
        } else {
            source = defaultAllowlistText
        }
        let parsed = parsePatterns(from: source)
        return parsed.isEmpty ? defaultAllowlistPatterns : parsed
    }

    static func isHostAllowed(_ host: String, defaults: UserDefaults = .standard) -> Bool {
        isHostAllowed(host, rawAllowlist: defaults.string(forKey: allowlistKey))
    }

    static func isHostAllowed(_ host: String, rawAllowlist: String?) -> Bool {
        guard let normalizedHost = normalizeHost(host) else { return false }
        return normalizedAllowlistPatterns(rawValue: rawAllowlist).contains { pattern in
            hostMatchesPattern(normalizedHost, pattern: pattern)
        }
    }

    static func addAllowedHost(_ host: String, defaults: UserDefaults = .standard) {
        guard let normalizedHost = normalizeHost(host) else { return }
        var patterns = normalizedAllowlistPatterns(defaults: defaults)
        guard !patterns.contains(normalizedHost) else { return }
        patterns.append(normalizedHost)
        defaults.set(patterns.joined(separator: "\n"), forKey: allowlistKey)
    }

    static func normalizeHost(_ rawHost: String) -> String? {
        var value = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty else { return nil }

        if let parsed = URL(string: value)?.host {
            return trimHost(parsed)
        }

        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }

        if let slash = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            value = String(value[..<slash])
        }

        if value.hasPrefix("[") {
            if let closing = value.firstIndex(of: "]") {
                value = String(value[value.index(after: value.startIndex)..<closing])
            } else {
                value.removeFirst()
            }
        } else if let colon = value.lastIndex(of: ":"),
                  value[value.index(after: colon)...].allSatisfy(\.isNumber),
                  value.filter({ $0 == ":" }).count == 1 {
            value = String(value[..<colon])
        }

        return trimHost(value)
    }

    private static func parsePatterns(from rawValue: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;\n\r\t")
        var out: [String] = []
        var seen = Set<String>()
        for token in rawValue.components(separatedBy: separators) {
            guard let normalized = normalizePattern(token) else { continue }
            guard seen.insert(normalized).inserted else { continue }
            out.append(normalized)
        }
        return out
    }

    private static func normalizePattern(_ rawPattern: String) -> String? {
        let trimmed = rawPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("*.") {
            let suffixRaw = String(trimmed.dropFirst(2))
            guard let suffix = normalizeHost(suffixRaw) else { return nil }
            return "*.\(suffix)"
        }

        return normalizeHost(trimmed)
    }

    private static func hostMatchesPattern(_ host: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        return host == pattern
    }

    private static func trimHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty else { return nil }

        // Canonicalize IDN entries (e.g. bücher.example -> xn--bcher-kva.example)
        // so user-entered allowlist patterns compare against URL.host consistently.
        if let canonicalized = URL(string: "https://\(trimmed)")?.host {
            return canonicalized
        }

        return trimmed
    }
}

func browserShouldBlockInsecureHTTPURL(
    _ url: URL,
    defaults: UserDefaults = .standard
) -> Bool {
    browserShouldBlockInsecureHTTPURL(
        url,
        rawAllowlist: defaults.string(forKey: BrowserInsecureHTTPSettings.allowlistKey)
    )
}

func browserShouldBlockInsecureHTTPURL(
    _ url: URL,
    rawAllowlist: String?
) -> Bool {
    guard url.scheme?.lowercased() == "http" else { return false }
    guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else { return true }
    return !BrowserInsecureHTTPSettings.isHostAllowed(host, rawAllowlist: rawAllowlist)
}

func browserShouldConsumeOneTimeInsecureHTTPBypass(
    _ url: URL,
    bypassHostOnce: inout String?
) -> Bool {
    guard let bypassHost = bypassHostOnce else { return false }
    guard url.scheme?.lowercased() == "http",
          let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else {
        return false
    }
    guard host == bypassHost else { return false }
    bypassHostOnce = nil
    return true
}

func browserShouldPersistInsecureHTTPAllowlistSelection(
    response: NSApplication.ModalResponse,
    suppressionEnabled: Bool
) -> Bool {
    guard suppressionEnabled else { return false }
    return response == .alertFirstButtonReturn || response == .alertSecondButtonReturn
}

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

enum BrowserFileSystemAccessBridge {
    static let scriptSource = """
    (() => {
      if (typeof window.showOpenFilePicker === "function") {
        return true;
      }
      if (window.__cmuxFileSystemAccessBridgeInstalled) {
        return true;
      }
      window.__cmuxFileSystemAccessBridgeInstalled = true;

      const makeDOMException = (name, message) => {
        try {
          return new DOMException(message, name);
        } catch (_) {
          const error = new Error(message);
          error.name = name;
          return error;
        }
      };

      const normalizeAcceptToken = (value) => {
        if (typeof value !== "string") {
          return null;
        }
        const token = value.trim();
        return token.length > 0 ? token : null;
      };

      const acceptStringFromTypes = (types) => {
        if (!Array.isArray(types)) {
          return "";
        }

        const seen = new Set();
        const tokens = [];
        const pushToken = (value) => {
          const token = normalizeAcceptToken(value);
          if (token && !seen.has(token)) {
            seen.add(token);
            tokens.push(token);
          }
        };

        for (const type of types) {
          const accept = type && type.accept;
          if (!accept || typeof accept !== "object") {
            continue;
          }

          for (const [mimeType, extensions] of Object.entries(accept)) {
            pushToken(mimeType);
            if (Array.isArray(extensions)) {
              for (const extension of extensions) {
                pushToken(extension);
              }
            } else {
              pushToken(extensions);
            }
          }
        }

        return tokens.join(",");
      };

      const FileSystemHandleShim = window.FileSystemHandle || function FileSystemHandle() {};
      const FileSystemFileHandleShim = window.FileSystemFileHandle || function FileSystemFileHandle() {};
      if (typeof window.FileSystemHandle !== "function") {
        Object.defineProperty(window, "FileSystemHandle", {
          value: FileSystemHandleShim,
          configurable: true,
          writable: true,
        });
      }
      if (typeof window.FileSystemFileHandle !== "function") {
        FileSystemFileHandleShim.prototype = Object.create(FileSystemHandleShim.prototype);
        Object.defineProperty(FileSystemFileHandleShim.prototype, "constructor", {
          value: FileSystemFileHandleShim,
          configurable: true,
          writable: true,
        });
        Object.defineProperty(window, "FileSystemFileHandle", {
          value: FileSystemFileHandleShim,
          configurable: true,
          writable: true,
        });
      }

      const makeFileHandle = (file) => {
        const handle = Object.create(window.FileSystemFileHandle.prototype);
        Object.defineProperties(handle, {
          kind: {
            value: "file",
            enumerable: true,
          },
          name: {
            value: file.name,
            enumerable: true,
          },
          getFile: {
            value: () => Promise.resolve(file),
          },
          isSameEntry: {
            value: (other) => Promise.resolve(other === handle),
          },
          queryPermission: {
            value: () => Promise.resolve("granted"),
          },
          requestPermission: {
            value: () => Promise.resolve("granted"),
          },
        });
        return handle;
      };

      const filePickerDismissedError = () => makeDOMException(
        "AbortError",
        "The file picker was dismissed."
      );

      const cleanupInput = (input) => {
        if (input && input.parentNode) {
          input.parentNode.removeChild(input);
        }
      };

      const showOpenFilePicker = (options = {}) => new Promise((resolve, reject) => {
        const input = document.createElement("input");
        input.type = "file";
        input.multiple = options && options.multiple === true;
        const accept = acceptStringFromTypes(options && options.types);
        if (accept) {
          input.accept = accept;
        }
        input.style.position = "fixed";
        input.style.left = "-10000px";
        input.style.top = "0";
        input.style.width = "1px";
        input.style.height = "1px";
        input.style.opacity = "0";
        input.tabIndex = -1;

        let settled = false;
        let focusFallbackScheduled = false;
        let focusFallbackTimer = null;
        const currentFiles = () => Array.from(input.files || []);
        const cleanup = () => {
          if (focusFallbackTimer !== null) {
            clearTimeout(focusFallbackTimer);
            focusFallbackTimer = null;
          }
          input.removeEventListener("change", handleChange);
          input.removeEventListener("cancel", handleCancel);
          window.removeEventListener("focus", handleWindowFocus);
          cleanupInput(input);
        };
        const settle = (callback) => {
          if (settled) {
            return;
          }
          settled = true;
          cleanup();
          callback();
        };

        const resolveFiles = () => {
          const files = currentFiles();
          settle(() => resolve(files.map(makeFileHandle)));
        };

        const dismissPicker = () => {
          settle(() => reject(filePickerDismissedError()));
        };

        function handleChange() {
          resolveFiles();
        }

        function handleCancel() {
          dismissPicker();
        }

        function handleWindowFocus() {
          if (settled || focusFallbackScheduled) {
            return;
          }
          focusFallbackScheduled = true;
          // Defer one turn so a selection-triggered change event can settle first.
          focusFallbackTimer = setTimeout(() => {
            focusFallbackTimer = null;
            if (settled) {
              return;
            }
            if (currentFiles().length > 0) {
              resolveFiles();
            } else {
              dismissPicker();
            }
          }, 0);
        }

        input.addEventListener("change", handleChange);
        input.addEventListener("cancel", handleCancel);
        window.addEventListener("focus", handleWindowFocus);

        try {
          (document.body || document.documentElement).appendChild(input);
          input.click();
        } catch (error) {
          settle(() => reject(error));
        }
      });

      Object.defineProperty(window, "showOpenFilePicker", {
        value: showOpenFilePicker,
        configurable: true,
        writable: true,
      });

      return true;
    })();
    """
}

func browserReadAccessURL(forLocalFileURL fileURL: URL, fileManager: FileManager = .default) -> URL? {
    guard fileURL.isFileURL, fileURL.path.hasPrefix("/") else { return nil }
    let path = fileURL.path
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
        return fileURL
    }

    let parent = fileURL.deletingLastPathComponent()
    guard !parent.path.isEmpty, parent.path.hasPrefix("/") else { return nil }
    return parent
}

@discardableResult
func browserLoadRequest(_ request: URLRequest, in webView: WKWebView) -> WKNavigation? {
    guard let url = request.url else { return nil }
    if url.isFileURL {
        guard let readAccessURL = browserReadAccessURL(forLocalFileURL: url) else { return nil }
        return webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
    }
    return webView.load(browserPreparedNavigationRequest(request))
}

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
    for url: URL,
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
            for: externalURL,
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

enum BrowserUserAgentSettings {
    // Force a Safari UA. Some WebKit builds return a minimal UA without Version/Safari tokens,
    // and some installs may have legacy Chrome UA overrides. Both can cause Google to serve
    // fallback/old UIs or trigger bot checks.
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15"
}

func normalizedBrowserHistoryNamespace(bundleIdentifier: String) -> String {
    if bundleIdentifier.hasPrefix("com.cmuxterm.app.debug.") {
        return "com.cmuxterm.app.debug"
    }
    if bundleIdentifier.hasPrefix("com.cmuxterm.app.staging.") {
        return "com.cmuxterm.app.staging"
    }
    return bundleIdentifier
}

func browserIsTemporaryHistoryURL(_ url: URL?) -> Bool {
    guard let url else { return false }
    if url.scheme?.lowercased() == CmuxDiffViewerURLSchemeHandler.scheme {
        return true
    }
    guard url.fragment == "cmux-diff-viewer",
          url.scheme?.lowercased() == "http",
          let host = url.host else {
        return false
    }
    return RemoteLoopbackProxyAlias.isLoopbackHost(host) ||
        RemoteLoopbackProxyAlias.localhostFamilyHost(
            forAliasHost: host,
            aliasHost: RemoteLoopbackProxyAlias.aliasHost
        ) != nil
}
