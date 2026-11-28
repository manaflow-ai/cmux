public import WebKit

/// Runs one of the driver's own scripts (the frame gate's, the capture
/// mask's, the secret target's) in a frame with a bound on how long it may
/// take. WebKit does not call a script's completion when a navigation
/// replaces the document it runs in, and a busy page answers late; past the
/// bound the call fails with `stale` instead of hanging the REPL call. The
/// script itself cannot be cancelled; a late answer is dropped. The script
/// runs without a user gesture (WebKit's `withUserGesture: NO`; a WebKit
/// without it fails the call with `unsupported`).
@MainActor
public struct BrowserReplScriptProbe {
    /// How long one script may take.
    public let timeout: Duration
    private let clock: any Clock<Duration>

    /// - Parameters:
    ///   - timeout: the bound on each script.
    ///   - clock: measures `timeout`.
    public nonisolated init(timeout: Duration = .seconds(5), clock: any Clock<Duration> = ContinuousClock()) {
        self.timeout = timeout
        self.clock = clock
    }

    /// Runs `source` (a `callAsyncJavaScript` function body) in `frame`.
    /// - Parameter what: What did not answer, for the `stale` error
    ///   ("frame 3 did not answer").
    public func call(
        _ source: String,
        arguments: [String: Any],
        in webView: WKWebView,
        frame: WKFrameInfo?,
        contentWorld: WKContentWorld,
        what: String
    ) async throws -> Any? {
        let race = ProbeRace()
        Task { @MainActor in
            do {
                // Without a user gesture: code that replaced a getter the
                // script reads in its world, or a page handler the script
                // sets off, must not copy or open a window with one.
                let value = try await webView.browserReplCallAsyncJavaScript(source, arguments: arguments, in: frame, contentWorld: contentWorld, userGesture: false)
                race.finish(.success(ProbeValue(value: value)))
            } catch {
                race.finish(.failure(error))
            }
        }
        let clock = self.clock
        let timeout = self.timeout
        let message = "\(what) within \(timeout.components.seconds) s (it may have navigated or be busy); try again"
        let deadline = Task { @MainActor in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            race.finish(.failure(BrowserReplDriverError(code: "stale", message: message.prefix(1).uppercased() + message.dropFirst())))
        }
        defer { deadline.cancel() }
        return try await race.value().value
    }
}

/// A probe's answer, carried between main-actor tasks.
private struct ProbeValue: @unchecked Sendable {
    let value: Any?
}

/// First answer wins: the script's or the timeout's.
@MainActor
private final class ProbeRace {
    private var result: Result<ProbeValue, any Error>?
    private var continuation: CheckedContinuation<ProbeValue, any Error>?

    func finish(_ value: Result<ProbeValue, any Error>) {
        guard result == nil else { return }
        result = value
        if let continuation {
            self.continuation = nil
            continuation.resume(with: value)
        }
    }

    func value() async throws -> ProbeValue {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            if let result {
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
            }
        }
    }
}
