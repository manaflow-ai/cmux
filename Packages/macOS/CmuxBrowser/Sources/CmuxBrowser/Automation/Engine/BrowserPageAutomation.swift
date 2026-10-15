import AppKit
public import Foundation
import WebKit

/// Browser automation operations on one ``BrowserPage``, whatever its engine.
///
/// `browser.*` socket methods and `cmux browser` commands resolve a surface,
/// take its panel's page, and run page operations through this type. Scripts
/// go through the page's own evaluation API on every engine. Operations
/// WebKit has no page API for (trusted keys, viewport emulation) and
/// operations Chromium carries out in the DevTools protocol (screenshots,
/// cookies) are dispatched here, by capability:
///
/// | Operation | Chromium (``BrowserEngineCapabilities/devToolsProtocol``) | WebKit |
/// | --- | --- | --- |
/// | Screenshot | `Page.captureScreenshot` | `takeSnapshot` |
/// | Cookies | `Network.getAllCookies` / `setCookie` / `deleteCookies` | `WKHTTPCookieStore` |
/// | Trusted keys | `Input.dispatchKeyEvent` | unsupported here (the app replays AppKit events) |
/// | Viewport | `Emulation.setDeviceMetricsOverride` | unsupported here (the app's viewport layout) |
///
/// Nothing here activates the app, raises a window or moves focus.
@MainActor
public struct BrowserPageAutomation {
    /// The page operated on.
    public let page: any BrowserPage
    private let codec = ChromiumDevToolsCodec()
    private let control = BrowserControlService()

    /// - Parameter page: the page to drive.
    public init(page: any BrowserPage) {
        self.page = page
    }

    /// The engine behind the page.
    public var engine: BrowserEngineKind { page.engineKind }

    private var speaksDevTools: Bool { page.capabilities.contains(.devToolsProtocol) }

    // MARK: - Scripts

    /// Evaluates a script and returns its completion value as Foundation
    /// objects (`NSNumber`, `String`, `NSNull`, arrays and dictionaries), or
    /// nil for `undefined`.
    public func evaluate(
        _ script: String,
        form: BrowserAutomationScriptForm,
        world: BrowserPageScriptWorld
    ) async throws(BrowserAutomationPageError) -> Any? {
        do {
            switch form {
            case .expression:
                return try await page.evaluateJavaScript(script, in: world)
            case .asyncFunctionBody:
                return try await page.callAsyncJavaScript(script, arguments: [:], in: world)
            }
        } catch {
            throw automationError(error)
        }
    }

    // MARK: - Screenshot

    /// PNG bytes of the visible viewport.
    public func captureViewportPNG() async throws(BrowserAutomationPageError) -> Data {
        if speaksDevTools {
            let json = try await devTools("Page.captureScreenshot", codec.screenshotParams)
            return try codec.screenshotPNG(fromJSON: json)
        }
        let image: NSImage
        do {
            image = try await page.takeSnapshot(rect: nil)
        } catch {
            throw automationError(error)
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw .engine(String(
                localized: "browser.automation.error.snapshotFailed",
                defaultValue: "The browser could not capture the page",
                bundle: .module
            ))
        }
        return png
    }

    // MARK: - Cookies

    /// Every cookie of the page's profile.
    public func allCookies() async throws(BrowserAutomationPageError) -> [HTTPCookie] {
        if speaksDevTools {
            return try codec.cookies(fromJSON: try await devTools("Network.getAllCookies", [:]))
        }
        let store = try webKitCookieStore()
        return await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    /// Stores `cookie` in the page's profile.
    public func setCookie(_ cookie: HTTPCookie) async throws(BrowserAutomationPageError) {
        if speaksDevTools {
            let json = try await devTools("Network.setCookie", codec.setCookieParams(cookie))
            guard codec.setCookieSucceeded(fromJSON: json) else {
                throw .engine(String(
                    localized: "browser.automation.error.cookieRejected",
                    defaultValue: "The browser rejected the cookie",
                    bundle: .module
                ))
            }
            return
        }
        let store = try webKitCookieStore()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    /// Deletes the cookie with `cookie`'s name, domain and path.
    public func deleteCookie(_ cookie: HTTPCookie) async throws(BrowserAutomationPageError) {
        if speaksDevTools {
            _ = try await devTools("Network.deleteCookies", codec.deleteCookieParams(cookie))
            return
        }
        let store = try webKitCookieStore()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.delete(cookie) {
                continuation.resume()
            }
        }
    }

    private func webKitCookieStore() throws(BrowserAutomationPageError) -> WKHTTPCookieStore {
        guard let webKit = page as? WebKitBrowserPage else { throw .unsupported("cookies") }
        return webKit.webView.configuration.websiteDataStore.httpCookieStore
    }

    // MARK: - Trusted input

    /// Whether ``dispatchKey(_:action:modifiers:)`` can deliver trusted keys
    /// to this page. WebKit pages use the app's AppKit event replay instead.
    public var supportsTrustedKeys: Bool { speaksDevTools }

    /// Delivers one key action to the page as trusted input.
    public func dispatchKey(
        _ event: BrowserKeyboardEvent,
        action: BrowserKeyboardAction,
        modifiers: BrowserKeyboardNativeModifiers
    ) async throws(BrowserAutomationPageError) {
        guard speaksDevTools else { throw .unsupported("trusted key input") }
        for params in codec.keyEventParams(event, action: action, modifiers: modifiers) {
            _ = try await devTools("Input.dispatchKeyEvent", params)
        }
    }

    // MARK: - Viewport

    /// Whether ``setViewportOverride(width:height:)`` can emulate a viewport
    /// on this page. WebKit pages use the panel's viewport layout instead.
    public var supportsViewportOverride: Bool { speaksDevTools }

    /// Overrides the layout viewport to `width` x `height` CSS pixels, or
    /// clears the override when either is nil.
    public func setViewportOverride(width: Int?, height: Int?) async throws(BrowserAutomationPageError) {
        guard speaksDevTools else { throw .unsupported("viewport emulation") }
        if let params = codec.viewportOverrideParams(width: width, height: height) {
            _ = try await devTools("Emulation.setDeviceMetricsOverride", params)
        } else {
            _ = try await devTools("Emulation.clearDeviceMetricsOverride", [:])
        }
    }

    // MARK: - DevTools protocol

    /// Runs one DevTools protocol method on the page and returns its result
    /// object as JSON text.
    public func devTools(_ method: String, _ params: [String: any Sendable]) async throws(BrowserAutomationPageError) -> String {
        let body: Data?
        if params.isEmpty {
            body = nil
        } else {
            body = Data(codec.jsonText(params).utf8)
        }
        let reply: Data
        do {
            reply = try await page.sendDevToolsProtocolMessage(method: method, params: body)
        } catch {
            throw automationError(error)
        }
        return String(decoding: reply, as: UTF8.self)
    }

    // MARK: - Errors

    /// Maps an engine error to the automation error the socket layer reports.
    func automationError(_ error: any Error) -> BrowserAutomationPageError {
        if let error = error as? BrowserAutomationPageError { return error }
        if let error = error as? BrowserEngineError {
            switch error {
            case .javaScript(let message): return .javaScript(message)
            case .pageClosed: return .pageUnavailable
            case .unavailable: return .pageUnavailable
            case .unsupported(let operation): return .unsupported(operation)
            }
        }
        let nsError = error as NSError
        if nsError.domain == WKError.errorDomain {
            return .javaScript(control.describeJavaScriptError(error))
        }
        return .engine(error.localizedDescription)
    }
}
