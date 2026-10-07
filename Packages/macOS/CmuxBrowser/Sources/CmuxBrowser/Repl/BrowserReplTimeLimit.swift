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
    /// `milliseconds`.
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
        defer {
            deadline.cancel()
        }
        let result = try await race.value()
        if race.timedOut { work.cancel() }
        return result
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
