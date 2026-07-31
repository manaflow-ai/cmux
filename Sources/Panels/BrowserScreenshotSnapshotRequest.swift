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
    private let completionGate = BrowserScreenshotContinuationGate<NSImage>()
    private var isCancelled = false

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
                guard completionGate.install(continuation) else { return }
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
        guard !completionGate.isFinished else { return }
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
        completionGate.finish(result)
    }
}
