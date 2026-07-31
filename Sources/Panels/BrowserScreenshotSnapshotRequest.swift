import AppKit
import WebKit

/// Owns one cancellable async bridge around `WKWebView.takeSnapshot(with:)`.
@MainActor
final class BrowserScreenshotSnapshotRequest {
    typealias SnapshotStarter = @MainActor (
        _ completion: @escaping @MainActor (NSImage?, Error?) -> Void
    ) -> Void

    private let startSnapshot: SnapshotStarter
    private let renderer: BrowserViewportSnapshotRenderer?
    private var continuation: CheckedContinuation<NSImage, Error>?
    private var isCancelled = false
    private var didFinish = false

    init(
        webView: WKWebView,
        configuration: WKSnapshotConfiguration,
        renderer: BrowserViewportSnapshotRenderer?
    ) {
        self.startSnapshot = { completion in
            webView.takeSnapshot(with: configuration, completionHandler: completion)
        }
        self.renderer = renderer
    }

    init(
        renderer: BrowserViewportSnapshotRenderer?,
        startSnapshot: @escaping SnapshotStarter
    ) {
        self.startSnapshot = startSnapshot
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
        startSnapshot { [weak self] image, error in
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
