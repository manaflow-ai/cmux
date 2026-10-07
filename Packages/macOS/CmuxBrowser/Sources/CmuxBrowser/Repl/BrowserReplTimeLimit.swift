/// Runs a driver call's work for at most a time limit on the injected
/// clock (`tab.navigate`'s wait, a timed `frame.evaluate`, a load-state
/// wait, printing): past the limit the call throws `timeout`.
@MainActor
public struct BrowserReplTimeLimit {
    private let sleeper: any BrowserReplSleeping

    public init(sleeper: any BrowserReplSleeping) {
        self.sleeper = sleeper
    }

    /// Runs `body`, throwing `timeout` when it has not finished after
    /// `milliseconds`, and `cancelled` when the calling task is cancelled
    /// first (the cell that made the call timed out, its session ended).
    ///
    /// `body` runs in a task of its own, which is cancelled whenever the
    /// call ends without its result: a call that ended keeps no work
    /// going, and each later step of that work that checks for
    /// cancellation (``BrowserReplFrameGate/checkTab(in:)``) stops before
    /// it reaches the tab. What `body` already handed WebKit (a script it
    /// sent) is not taken back; a caller that started a navigation stops
    /// it itself.
    ///
    /// - Parameter what: what the call was doing, for the error
    ///   (`Timeout 100ms exceeded while <what>`).
    public func run<T>(
        milliseconds: Int,
        what: String,
        _ body: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let race = BrowserReplRace<T>()
        let work = Task { @MainActor in
            do {
                race.finish(.success(try await body()))
            } catch {
                race.finish(.failure(error))
            }
        }
        let sleeper = self.sleeper
        let deadline = Task { @MainActor in
            do {
                try await sleeper.sleep(for: .milliseconds(milliseconds))
            } catch {
                return
            }
            race.finish(.failure(BrowserReplDriverError(code: "timeout", message: "Timeout \(milliseconds)ms exceeded\(what.isEmpty ? "" : " while \(what)")")))
        }
        // Both end with the call, whichever way it ends (the timeout throws
        // out of the wait below); cancelling finished work does nothing.
        defer {
            deadline.cancel()
            work.cancel()
        }
        return try await withTaskCancellationHandler {
            try await race.value()
        } onCancel: {
            work.cancel()
            Task { @MainActor in
                race.finish(.failure(BrowserReplDriverError(code: "cancelled", message: "cancelled because the cell that made the call timed out or its session ended; nothing more was sent to the tab")))
            }
        }
    }
}

/// First-result-wins completion for ``BrowserReplTimeLimit``.
@MainActor
private final class BrowserReplRace<T> {
    /// The result as it crosses the continuation. It is made, stored and
    /// read on the main actor only.
    private struct Outcome: @unchecked Sendable {
        let result: Result<T, any Error>
    }

    private var result: Result<T, any Error>?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private(set) var timedOut = false

    func finish(_ value: Result<T, any Error>) {
        guard result == nil else { return }
        if case .failure(let error as BrowserReplDriverError) = value, error.code == "timeout" {
            timedOut = true
        }
        result = value
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: Outcome(result: value))
        }
    }

    func value() async throws -> T {
        if let result { return try result.get() }
        return try await withCheckedContinuation { continuation in
            self.continuation = continuation
        }.result.get()
    }
}
