import Foundation
import Testing

@testable import CmuxBrowser

/// A fetch's URL session task can complete (cancelled) before the fetch
/// waits for it: the Swift task was cancelled before or while the fetch
/// started. The fetch must then return, never wait forever on a task
/// whose completion was already delivered.
@Suite("Browser REPL fetch cancellation", .serialized)
struct BrowserReplFetchCancellationTests {
    /// Resumes a continuation with the first value given; later ones are dropped.
    final class FirstValue<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        func wait(_ start: () -> Void) async -> T {
            await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                start()
            }
        }

        func resume(_ value: T) {
            let continuation: CheckedContinuation<T, Never>? = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: value)
        }
    }

    /// The fetch's result, or nil when it has not returned within `seconds`.
    private func fetchResult(
        within seconds: Int,
        _ operation: @escaping @Sendable () async -> Result<String, BrowserReplDriverError>
    ) async -> Result<String, BrowserReplDriverError>? {
        let first = FirstValue<Result<String, BrowserReplDriverError>?>()
        return await first.wait {
            Task { first.resume(await operation()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                first.resume(nil)
            }
        }
    }

    private func requestJSON(port: UInt16) -> String {
        let request: [String: Any] = [
            "url": "http://127.0.0.1:\(port)/target",
            "method": "GET",
            "headers": [] as [[String]],
            "credentials": "omit",
        ]
        return JSONSerialization.browserReplString(request) ?? "{}"
    }

    @Test("A fetch whose task completes before the fetch waits for it returns")
    func completionBeforeWaitingReturns() async throws {
        let server = try BrowserReplTestHTTPServer { _, _, _ in (200, [:], Data("sent".utf8)) }
        try await server.start()
        defer { server.stop() }
        let driver = HeldCookiesDriver()
        driver.releaseAll()
        let fetcher = BrowserReplFetcher(driver: driver)
        defer { fetcher.invalidate() }
        // The task is cancelled and its completion delivered in the window
        // between the collector's registration and the wait, as URLSession
        // does when the Swift task is cancelled in that window.
        fetcher.beforeWaiting = { [weak fetcher] task in
            guard let fetcher else { return }
            task.cancel()
            fetcher.urlSession(URLSession.shared, task: task, didCompleteWithError: URLError(.cancelled))
        }

        let json = requestJSON(port: server.port)
        let result = await fetchResult(within: 10) { await fetcher.fetch(requestJSON: json) }
        guard let result else {
            Issue.record("the fetch never returned after its task completed before it waited")
            return
        }
        guard case .failure = result else {
            Issue.record("a cancelled fetch succeeded: \(result)")
            return
        }
    }

    @Test("A fetch started by a cancelled task fails as cancelled without sending the request")
    func cancelledTaskFetchFailsAsCancelled() async throws {
        let requests = BrowserReplResponseCounter()
        let server = try BrowserReplTestHTTPServer { _, _, _ in
            requests.increment()
            return (200, [:], Data("sent".utf8))
        }
        try await server.start()
        defer { server.stop() }
        let driver = HeldCookiesDriver()
        driver.releaseAll()
        let fetcher = BrowserReplFetcher(driver: driver)
        defer { fetcher.invalidate() }

        let json = requestJSON(port: server.port)
        let result = await fetchResult(within: 10) {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fetcher.fetch(requestJSON: json)
        }
        guard let result else {
            Issue.record("the fetch of a cancelled task never returned")
            return
        }
        guard case .failure(let error) = result else {
            Issue.record("the fetch of a cancelled task succeeded: \(result)")
            return
        }
        #expect(error.code == "cancelled", "\(error)")
        #expect(requests.count == 0, "the server received \(requests.count) request(s)")
    }
}
