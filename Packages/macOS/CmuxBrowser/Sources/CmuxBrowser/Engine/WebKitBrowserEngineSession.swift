public import AppKit
public import CmuxCore
public import Foundation
public import WebKit

/// A ``BrowserEngineSession`` backed by an in-process `WKWebView`.
@MainActor
public final class WebKitBrowserEngineSession: BrowserEngineSession {
    /// The engine family implementing this session.
    public let kind = BrowserEngineKind.webKit

    /// WebKit owns its helper processes outside this engine session.
    public var contentProcessIdentifier: Int32? { nil }

    /// The wrapped WebKit view.
    public let webView: WKWebView

    /// The native view hosted by the browser pane portal.
    public var contentView: NSView { webView }

    /// The page zoom factor applied by WebKit.
    public var pageZoomFactor: CGFloat { webView.pageZoom }

    /// The latest WebKit state snapshot.
    public private(set) var state: BrowserEngineState

    /// State snapshots emitted from WebKit KVO signals.
    public let stateUpdates: AsyncStream<BrowserEngineState>

    private let stateContinuation: AsyncStream<BrowserEngineState>.Continuation
    private var observations: [NSKeyValueObservation] = []

    /// Creates a WebKit engine session around an app-configured web view.
    ///
    /// - Parameter webView: The view whose configuration and delegates are owned by the app.
    public init(webView: WKWebView) {
        self.webView = webView
        self.state = BrowserEngineState(
            url: webView.url,
            title: webView.title ?? "",
            isLoading: webView.isLoading,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward
        )
        (stateUpdates, stateContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        installObservations()
    }

    /// Loads a request in WebKit.
    public func load(_ request: URLRequest) { webView.load(request) }

    /// Traverses backward in WebKit history.
    public func goBack() { webView.goBack() }

    /// Traverses forward in WebKit history.
    public func goForward() { webView.goForward() }

    /// Reloads the current page.
    public func reload() { webView.reload() }

    /// Reloads from origin, bypassing WebKit caches.
    public func reloadFromOrigin() { webView.reloadFromOrigin() }

    /// Stops the active WebKit load.
    public func stopLoading() { webView.stopLoading() }

    /// Applies WebKit's native page zoom factor.
    public func setPageZoomFactor(_ pageZoomFactor: CGFloat) {
        webView.pageZoom = pageZoomFactor
    }

    /// Keeps WebKit active because its native view owns offscreen presentation throttling.
    public func setViewportVisible(_: Bool) {}

    /// Evaluates a JavaScript expression in a WebKit content world and awaits any returned promise.
    public func evaluateJavaScript(
        _ script: String,
        in world: BrowserJavaScriptWorld
    ) async throws -> BrowserJavaScriptValue {
        let contentWorld: WKContentWorld = switch world {
        case .page: .page
        case .isolated: .defaultClient
        }
        return try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                "return await eval(script);",
                arguments: ["script": script],
                in: nil,
                in: contentWorld
            ) { result in
                switch result {
                case .success(let value):
                    do {
                        continuation.resume(returning: try BrowserJavaScriptValue(foundationValue: value))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Installs a WebKit user script for future documents.
    public func addInitializationScript(_ script: String) async throws {
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
    }

    /// Reads cookies from the WebKit website data store.
    public func cookies() async throws -> [BrowserEngineCookie] {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.map { cookie in
                    BrowserEngineCookie(
                        name: cookie.name,
                        value: cookie.value,
                        domain: cookie.domain,
                        path: cookie.path,
                        isSecure: cookie.isSecure,
                        isHTTPOnly: cookie.isHTTPOnly,
                        expiresDate: cookie.expiresDate
                    )
                })
            }
        }
    }

    /// Creates or replaces a cookie in the WebKit website data store.
    public func setCookie(_ cookie: BrowserEngineCookie) async throws {
        let httpCookie = try makeHTTPCookie(cookie)
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(httpCookie) {
                continuation.resume()
            }
        }
    }

    /// Deletes a cookie from the WebKit website data store.
    public func deleteCookie(_ cookie: BrowserEngineCookie) async throws {
        let httpCookie = try makeHTTPCookie(cookie)
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.delete(httpCookie) {
                continuation.resume()
            }
        }
    }

    /// Captures a PNG snapshot of the current WebKit viewport.
    public func captureScreenshot() async throws -> Data {
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, any Error>) in
            webView.takeSnapshot(with: nil) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: BrowserEngineSessionError.emptyScreenshot)
                }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            throw BrowserEngineSessionError.emptyScreenshot
        }
        return png
    }

    /// Stops loading and finishes the state stream.
    public func close() {
        observations.removeAll()
        webView.stopLoading()
        stateContinuation.finish()
    }

    private func installObservations() {
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publishState() }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publishState() }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publishState() }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publishState() }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publishState() }
            },
        ]
    }

    private func makeHTTPCookie(_ cookie: BrowserEngineCookie) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .domain: cookie.domain,
            .path: cookie.path,
        ]
        if cookie.isSecure {
            properties[.secure] = "TRUE"
        }
        if cookie.isHTTPOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        if let expiresDate = cookie.expiresDate {
            properties[.expires] = expiresDate
        }
        guard let httpCookie = HTTPCookie(properties: properties) else {
            throw WebKitBrowserEngineCookieError.invalidPayload
        }
        return httpCookie
    }

    private func publishState() {
        state = BrowserEngineState(
            url: webView.url,
            title: webView.title ?? "",
            isLoading: webView.isLoading,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward
        )
        stateContinuation.yield(state)
    }
}
