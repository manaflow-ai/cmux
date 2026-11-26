import CmuxEgress
public import Foundation
import CmuxNextCompat

/// A new socket for a Cloud API request whose connection goes nowhere.
///
/// Some network paths black-hole one connection's 5-tuple: its SYN and every retransmit of it are
/// dropped, while a new socket (a new source port) to the same host connects in milliseconds.
/// Measured on 2026-11-17: 1 in 8 to 1 in 2 new connections to the Cloud API host, each waiting
/// the session's whole 15 s request timeout. URLSession says nothing about a request's connect, so
/// what may be sent again is decided by what the request is (``Replay``):
///
/// - a read (`v1/read`, `v1/auth/challenge`, any GET) is hedged: a second attempt on a fresh
///   session (its own connection pool, so a new socket) after ``stagger`` while the first has not
///   answered, a third after another, and the first answer wins; the others are cancelled.
/// - a keyed mutation (a JSON body with an `idempotency_key`) is sent once more, on a fresh
///   session with the same key, after a connection-class failure. Never in parallel.
/// - anything else is sent once, as before.
public struct CloudConnectHedge: Sendable {
    /// How a request may be sent again.
    public enum Replay: Sendable, Equatable {
        /// Racing copies cost nothing but a read.
        case hedge
        /// Sent again after a connection failure, with the same idempotency key.
        case retryOnce
        /// Sent once.
        case never
    }

    /// Whether a request may have reached the server before its last attempt: noted each time an attempt after the
    /// first starts (a keyed mutation's resend after a connection failure, or a raced read). A direct create reads it
    /// (``CloudPersonCreate/ops(_:after:)``): a refusal answered to its resend does not prove the first never ran.
    public final class Resends: Sendable {
        private let count = Mutex(0)
        public init() {}
        /// An attempt after the first started.
        public func note() { count.withLock { $0 += 1 } }
        /// Whether one did.
        public var any: Bool { count.withLock { $0 > 0 } }
    }

    /// The ``Resends`` the requests sent in this task note on (``data(for:on:)``).
    @TaskLocal public static var resends: Resends?

    /// How long the newest attempt of a hedged read has alone before the next starts.
    public var stagger: Duration
    /// Attempts of a hedged read in all.
    public var maxAttempts: Int

    // short-gate: a hedge, not a give-up; each attempt keeps the read's own deadline.
    public init(stagger: Duration = .seconds(1), maxAttempts: Int = 3) {
        self.stagger = stagger
        self.maxAttempts = max(1, maxAttempts)
    }

    /// The replay a POST to `path` with `body` allows (``Replay``).
    public static func replay(path: String, body: Data?) -> Replay {
        if path.hasSuffix("v1/read") || path.hasSuffix("v1/auth/challenge") { return .hedge }
        if let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let key = object["idempotency_key"] as? String, !key.isEmpty {
            return .retryOnce
        }
        return .never
    }

    /// The replay `request` allows: a GET is a read, a POST is ``replay(path:body:)``'s.
    public static func replay(of request: URLRequest) -> Replay {
        if (request.httpMethod ?? "GET").uppercased() == "GET" { return .hedge }
        return replay(path: request.url?.path ?? "", body: request.httpBody)
    }

    /// Whether `error` says the request found no working connection (where a new socket helps).
    public static func isConnectionFailure(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// `request` on `session`, hedged or retried as ``replay(of:)`` allows. A fresh session refuses
    /// redirects, as every Cloud API session does.
    public func data(for request: URLRequest, on session: URLSession) async throws -> (Data, URLResponse) {
        let resends = Self.resends
        return try await send(replay: Self.replay(of: request), clock: ContinuousClock()) { attempt in
            guard attempt > 0 else { return try await session.data(for: request) }
            resends?.note()
            let fresh = CmuxEgress.session(site: "CmuxNextCloud.CloudConnectHedge", configuration: session.configuration, delegate: HedgeRefusesRedirects(), delegateQueue: nil)
            defer { fresh.finishTasksAndInvalidate() }
            return try await fresh.data(for: request)
        }
    }

    /// Runs `attempt(n)` as `replay` allows, the hedge's stagger on `clock`: attempt 0 always, more
    /// for ``Replay/hedge`` (``race(clock:_:)``) and one more for ``Replay/retryOnce`` after a
    /// connection failure.
    public func send<T: Sendable, C: Clock & Sendable>(replay: Replay, clock: C,
                                                      _ attempt: @escaping @Sendable (Int) async throws -> T) async throws -> T
        where C.Duration == Duration {
        switch replay {
        case .hedge:
            return try await race(clock: clock, attempt)
        case .retryOnce:
            do {
                return try await attempt(0)
            } catch let error where Self.isConnectionFailure(error) && !Task.isCancelled {
                return try await attempt(1)
            }
        case .never:
            return try await attempt(0)
        }
    }

    /// Starts `attempt(0)`, then another every ``stagger`` (or at once when every running one
    /// failed) up to ``maxAttempts``; the first to answer wins and the rest are cancelled. When all
    /// fail, the last failure is thrown.
    public func race<T: Sendable, C: Clock & Sendable>(clock: C,
                                                      _ attempt: @escaping @Sendable (Int) async throws -> T) async throws -> T
        where C.Duration == Duration {
        let stagger = stagger
        let maxAttempts = maxAttempts
        // concurrency-allow: every attempt is a cancellable URLSession load and the stagger a clock sleep; the group cancels the losers
        return try await withThrowingTaskGroup(of: HedgeEvent<T>.self) { group in
            var launched = 0
            var running = 0
            var timerPending = false
            var launchNow = true
            var lastError: (any Error)?
            // wakeup-allow: each turn awaits the group's next attempt or stagger event; at most maxAttempts attempts and timers
            while true {
                try Task.checkCancellation()
                if launchNow && launched < maxAttempts {
                    let n = launched
                    group.addTask {
                        do { return .answered(try await attempt(n)) } catch { return .failed(error) }
                    }
                    launched += 1
                    running += 1
                    if launched < maxAttempts && !timerPending {
                        group.addTask {
                            // wakeup-allow: one-shot stagger before a hedged connect attempt (CloudConnectHedge)
                            try? await clock.sleep(for: stagger)
                            return .due
                        }
                        timerPending = true
                    }
                }
                launchNow = false
                if running == 0 { break }
                guard let event = try await group.next() else { break }
                switch event {
                case .answered(let value):
                    group.cancelAll()
                    return value
                case .failed(let error):
                    running -= 1
                    lastError = error
                    // A failure frees its turn: with none left running, the next starts now.
                    launchNow = running == 0
                case .due:
                    timerPending = false
                    launchNow = true
                }
            }
            group.cancelAll()
            throw lastError ?? CancellationError()
        }
    }
}

/// One event of ``CloudConnectHedge/race(clock:_:)``'s group.
private enum HedgeEvent<T: Sendable>: Sendable {
    case answered(T)
    case failed(any Error)
    case due
}

/// Answers every redirect with "do not follow" (the completion-handler form: the async delegate form
/// crashes swift 6.4 SILGen in this module, as `InstallHTTPTransport`'s does).
private final class HedgeRefusesRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
