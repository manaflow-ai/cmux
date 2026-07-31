import AppKit
import WebKit

/// Owns one cancellable async bridge around `WKWebView.takeSnapshot(with:)`.
@MainActor
final class BrowserScreenshotSnapshotRequest {
    private weak var webView: WKWebView?
    private let configuration: WKSnapshotConfiguration
    private let renderer: BrowserViewportSnapshotRenderer?
    private var continuation: CheckedContinuation<NSImage, Error>?
    private var isCancelled = false
    private var didFinish = false

    init(
        webView: WKWebView,
        configuration: WKSnapshotConfiguration,
        renderer: BrowserViewportSnapshotRenderer?
    ) {
        self.webView = webView
        self.configuration = configuration
        self.renderer = renderer
    }

    func capture() async throws -> NSImage {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled, !isCancelled else {
                    finish(.failure(CancellationError()))
                    return
                }
                start()
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    private func start() {
        guard let webView else {
            finish(.failure(BrowserScreenshotError.emptySnapshot))
            return
        }
        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            self?.complete(image: image, error: error)
        }
    }

    private func complete(image: NSImage?, error: Error?) {
        guard !didFinish else { return }
        guard let image else {
            finish(.failure(error ?? BrowserScreenshotError.emptySnapshot))
            return
        }
        guard let renderer else {
            finish(.success(image))
            return
        }
        guard let normalized = renderer.normalizedImage(image) else {
            finish(.failure(BrowserScreenshotError.invalidImageRepresentation))
            return
        }
        finish(.success(normalized))
    }

    private func cancel() {
        isCancelled = true
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<NSImage, Error>) {
        guard !didFinish else { return }
        didFinish = true
        continuation?.resume(with: result)
        continuation = nil
    }
}
