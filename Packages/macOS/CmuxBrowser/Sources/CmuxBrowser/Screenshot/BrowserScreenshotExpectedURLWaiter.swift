public import Foundation
public import WebKit

/// Waits until a `WKWebView` settles on an expected URL before a screenshot is
/// captured, so the snapshot reflects the requested page rather than a stale or
/// still-loading one.
///
/// The waiter is ready when the live URL matches the expected URL under
/// ``ExpectedURLMatcher`` tolerances and the web view has finished loading. It
/// observes `url` and `isLoading` via KVO and arms a timeout; the first of
/// (already-ready, an observation that becomes ready, the timeout, or an
/// explicit cancel) resolves the wait. Two driving styles are offered: an
/// `async` form bridged through a `CheckedContinuation` with task-cancellation
/// wired to ``cancel()``, and a completion-handler form. The static
/// `waitForExpectedURLIfNeeded` entry points apply the "skip when no URL was
/// requested" guard and own waiter lifetime, so callers do not construct the
/// waiter directly.
///
/// Safety: BrowserScreenshotExpectedURLWaiter keeps WKWebView, KVO tokens,
/// Timer, and CheckedContinuation main-actor-only and never sends them across
/// threads.
@MainActor
public final class BrowserScreenshotExpectedURLWaiter: @unchecked Sendable {
    private weak var webView: WKWebView?
    private let expectedAbsoluteString: String
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Void, any Error>?
    private var completion: ((Result<Void, any Error>) -> Void)?
    private var urlObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var timeoutTimer: Timer?
    private var isCancelled = false

    init(webView: WKWebView, expectedAbsoluteString: String, timeout: TimeInterval) {
        self.webView = webView
        self.expectedAbsoluteString = expectedAbsoluteString
        self.timeout = timeout
    }

    /// Awaits `webView` settling on `expectedURL`, returning immediately when no
    /// URL was requested and wiring task cancellation to ``cancel()``.
    /// - Parameters:
    ///   - webView: the web view whose URL and loading state are observed.
    ///   - expectedURL: the URL the snapshot should capture, or `nil` to skip.
    public static func waitForExpectedURLIfNeeded(_ webView: WKWebView, expectedURL: URL?) async throws {
        guard let expectedURL else { return }
        let waiter = BrowserScreenshotExpectedURLWaiter(
            webView: webView,
            expectedAbsoluteString: expectedURL.absoluteString,
            timeout: 5.0
        )

        try await withTaskCancellationHandler {
            try await waiter.wait()
        } onCancel: {
            Task { @MainActor in
                waiter.cancel()
            }
        }
    }

    /// Awaits `webView` settling on `expectedURL`, completing immediately with
    /// success when no URL was requested.
    /// - Parameters:
    ///   - webView: the web view whose URL and loading state are observed.
    ///   - expectedURL: the URL the snapshot should capture, or `nil` to skip.
    ///   - completion: invoked on the main actor with success once ready, or the
    ///     failure that ended the wait.
    public static func waitForExpectedURLIfNeeded(
        _ webView: WKWebView,
        expectedURL: URL?,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guard let expectedURL else {
            completion(.success(()))
            return
        }
        let waiter = BrowserScreenshotExpectedURLWaiter(
            webView: webView,
            expectedAbsoluteString: expectedURL.absoluteString,
            timeout: 5.0
        )
        waiter.wait { [waiter] result in
            _ = waiter
            completion(result)
        }
    }

    func wait() async throws {
        try Task.checkCancellation()
        if isReady {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            installObservers()
            if isCancelled {
                finish(.failure(CancellationError()))
                return
            }
            if isReady {
                finish(.success(()))
            }
        }
    }

    func wait(completion: @escaping (Result<Void, any Error>) -> Void) {
        if isReady {
            completion(.success(()))
            return
        }

        self.completion = completion
        installObservers()
        if isCancelled {
            finish(.failure(CancellationError()))
            return
        }
        if isReady {
            finish(.success(()))
        }
    }

    func cancel() {
        isCancelled = true
        finish(.failure(CancellationError()))
    }

    private var isReady: Bool {
        guard let webView,
              let currentURL = webView.url,
              ExpectedURLMatcher(expectedAbsoluteString: expectedAbsoluteString)
                .matches(currentURL),
              !webView.isLoading else {
            return false
        }
        return true
    }

    private func installObservers() {
        guard let webView else {
            finish(.failure(BrowserScreenshotError.emptySnapshot))
            return
        }

        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishIfReady()
                }
            }
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishIfReady()
                }
            }
        }
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finish(.failure(BrowserScreenshotError.emptySnapshot))
                }
            }
        }
    }

    private func finishIfReady() {
        if isReady {
            finish(.success(()))
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard continuation != nil || completion != nil else { return }
        let continuation = self.continuation
        let completion = self.completion
        self.continuation = nil
        self.completion = nil
        urlObservation = nil
        loadingObservation = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        if let continuation {
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
        completion?(result)
    }
}
