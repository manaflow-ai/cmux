import CmuxEgress
import Foundation

/// The URLSession ``LiveAPI`` sends on, replaced by a fresh one (a fresh connection pool) after a request fails the
/// way a request on a pooled connection the phone's network left behind fails.
///
/// A phone that hops Wi-Fi <-> cellular keeps its HTTP/2 and HTTP/3 connections to the service in the session's
/// pool, and the next request rides the old one until its timeout: Leo's phone (TestFlight 1cd15370, 2026-11-27)
/// saw 2,891 path changes in 15 minutes and every cloud call it made (Mac discovery, presence, workspaces) end in
/// -1001 while the link reconnected. One failure on a session moves every later request to a fresh session, and
/// ``LiveAPI/send(_:)`` sends an idempotent request (or one that never left) there again once.
final class APISessions: @unchecked Sendable {
    /// The one every ``LiveAPI`` made without its own session shares, so one stale failure renews them all.
    static let shared = APISessions(make: { CmuxEgress.session(site: "CmuxMobileLive.LiveAPI") })

    /// Failures that say the connection, not the service, is gone.
    static let staleCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .secureConnectionFailed,
    ]
    /// Failures after which the request never reached the service, so sending it again is safe for any method.
    static let notSentCodes: Set<URLError.Code> = [.notConnectedToInternet, .cannotConnectToHost]

    private let lock = NSLock()
    private let make: @Sendable () -> URLSession
    private var current: URLSession?
    private var renewed = 0

    init(_ first: URLSession? = nil, make: @escaping @Sendable () -> URLSession) {
        current = first
        self.make = make
    }

    /// The session to send on now.
    var session: URLSession {
        lock.withLock {
            if let current { return current }
            let made = make()
            current = made
            return made
        }
    }

    /// How many times a stale failure replaced the session.
    var renewals: Int { lock.withLock { renewed } }

    /// The session after `stale` failed: a new one, unless another request already replaced `stale`. The old one
    /// is left to finish its own tasks, not invalidated: another ``LiveAPI`` may be starting a task on it.
    func renew(after stale: URLSession) -> URLSession {
        lock.withLock {
            if let current, current !== stale { return current }
            let made = make()
            current = made
            renewed += 1
            return made
        }
    }

    static func isStale(_ error: any Error) -> Bool {
        (error as? URLError).map { staleCodes.contains($0.code) } ?? false
    }

    static func wasNotSent(_ error: any Error) -> Bool {
        (error as? URLError).map { notSentCodes.contains($0.code) } ?? false
    }
}
