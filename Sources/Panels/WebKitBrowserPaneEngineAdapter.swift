import AppKit
import CmuxBrowser
import Foundation
import WebKit

/// Keeps the existing WKWebView implementation behind the shared engine seam.
@MainActor
final class WebKitBrowserPaneEngineAdapter: BrowserPaneEngineAdapter {
    let kind: BrowserEngineKind = .webkit
    let webView: WKWebView
    private var lifecycleGeneration: UInt64 = 0

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
        lifecycleGeneration &+= 1
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
        let generation = lifecycleGeneration
        let gate = CallbackGate<CDPValue>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard generation == lifecycleGeneration else {
                    gate.fail(CancellationError())
                    return
                }
            if #available(macOS 11.0, *), awaitPromise {
                webView.callAsyncJavaScript(
                    script,
                    arguments: [:],
                    in: nil,
                    in: .page
                ) { result in
                    switch result {
                    case .success(let value):
                        gate.succeed(CDPValue(any: value))
                    case .failure(let error):
                        gate.fail(error)
                    }
                }
            } else {
                webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        gate.fail(error)
                    } else {
                        gate.succeed(CDPValue(any: value))
                    }
                }
            }
            }
        } onCancel: {
            gate.fail(CancellationError())
        }
    }

    func screenshotPNG() async throws -> Data {
        let generation = lifecycleGeneration
        let gate = CallbackGate<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard generation == lifecycleGeneration else {
                    gate.fail(CancellationError())
                    return
                }
            let configuration = WKSnapshotConfiguration()
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    gate.fail(error)
                    return
                }
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let representation = NSBitmapImageRep(data: tiff),
                      let data = representation.representation(using: .png, properties: [:]) else {
                    gate.fail(CDPError.protocolError(String(
                        localized: "browser.screenshot.error.emptySnapshot",
                        defaultValue: "No screenshot was returned."
                    )))
                    return
                }
                gate.succeed(data)
            }
            }
        } onCancel: {
            gate.fail(CancellationError())
        }
    }
}

/// Protects checked continuations from WebKit callbacks racing task
/// cancellation or pane replacement. WebKit may invoke its completion after
/// `stopLoading`; resuming twice would otherwise crash the process.
private final class CallbackGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var cancelled = false

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func succeed(_ value: Value) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(returning: value)
    }

    func fail(_ error: any Error) {
        lock.lock(); cancelled = error is CancellationError; let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(throwing: error)
    }
}
