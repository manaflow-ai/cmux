import AppKit
import CmuxBrowser
import Foundation
import WebKit

/// Keeps the existing WKWebView implementation behind the shared engine seam.
@MainActor
final class WebKitBrowserPaneEngineAdapter: BrowserPaneEngineAdapter {
    let kind: BrowserEngineKind = .webkit
    let webView: WKWebView

    var contentView: NSView? { webView }
    var remoteDebuggingEndpoint: BrowserCDPEndpoint? { nil }
    var startupReadinessTask: Task<Void, Never>? { nil }

    init(webView: WKWebView) {
        self.webView = webView
    }

    func start(initialURL: URL?) {
        _ = initialURL
    }

    func stop() {
        webView.stopLoading()
    }

    func navigate(to url: URL) async throws {
        webView.load(URLRequest(url: url))
    }

    func goBack() async throws {
        webView.goBack()
    }

    func goForward() async throws {
        webView.goForward()
    }

    func reload() async throws {
        webView.reload()
    }

    func hardReload() async throws {
        webView.reloadFromOrigin()
    }

    func evaluateJavaScript(_ script: String, awaitPromise: Bool) async throws -> CDPValue {
        try await withCheckedThrowingContinuation { continuation in
            if #available(macOS 11.0, *), awaitPromise {
                webView.callAsyncJavaScript(
                    script,
                    arguments: [:],
                    in: nil,
                    in: .page
                ) { result in
                    switch result {
                    case .success(let value):
                        continuation.resume(returning: CDPValue(any: value))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            } else {
                webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: CDPValue(any: value))
                    }
                }
            }
        }
    }

    func screenshotPNG() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = WKSnapshotConfiguration()
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let representation = NSBitmapImageRep(data: tiff),
                      let data = representation.representation(using: .png, properties: [:]) else {
                    continuation.resume(throwing: CDPError.protocolError(String(
                        localized: "browser.screenshot.error.emptySnapshot",
                        defaultValue: "No screenshot was returned."
                    )))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}
