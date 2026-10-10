import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import os

/// Where a lease's access token comes from: the signed-in account
/// (`CloudAuth` in the app, a fake in tests).
protocol CloudLeaseTokens: AnyObject {
    var isSignedIn: Bool { get }
    func accessToken(forceRefresh: Bool) async throws -> String
}

/// The daemon side of a lease (`CloudConversationClient` in the app).
nonisolated protocol CloudLeaseSessions: Sendable {
    func setSession(_ request: CloudSessionSetRequest) async throws -> CloudSessionState
    func clearSession() async throws -> CloudSessionState
}

extension CloudConversationClient: CloudLeaseSessions {}

extension CloudAuth: CloudLeaseTokens {
    func accessToken(forceRefresh: Bool) async throws -> String {
        forceRefresh ? try await coordinator.forceRefreshAccessToken() : try await tokens().access
    }
}

/// The cloud session lease the app gives the local daemon
/// (home-cloud-proxy.md section 2). CloudAuth (the signed-in trusted local
/// client) owns the Stack session; the daemon holds the current access token
/// in memory only and asks for a new one with `cloud-session-needed`.
///
/// Each lease is for one named account: a token whose `sub` is another
/// account is never leased, so the account the cloud source acts as is the
/// account the daemon's lease holds. Lease work runs one at a time, in the
/// order it was asked for, so an older lease never lands after a newer one.
final class HomeCloudLease {
    enum Outcome: Equatable, Sendable {
        /// The daemon holds a lease for this account (the token's `sub`),
        /// until `expiresAt` (Unix milliseconds, what `cloud-session-needed`
        /// names for it).
        case leased(subject: String, expiresAt: UInt64)
        /// No account was asked for: the daemon holds no lease.
        case signedOut
        /// No lease for the account asked for.
        case failed
        /// Newer lease work replaced this one before it finished.
        case superseded
    }

    private enum Refusal: Error {
        case signedOut, noOrigin, otherAccount
    }

    private let tokens: any CloudLeaseTokens
    private let apiBaseURL: URL
    private let clientVersion: String?
    private let logger: Logger
    /// The newest lease work; the next waits for it.
    private var leasing: Task<Outcome, Never>?

    init(tokens: any CloudLeaseTokens, apiBaseURL: URL, clientVersion: String?, logger: Logger) {
        self.tokens = tokens
        self.apiBaseURL = apiBaseURL
        self.clientVersion = clientVersion
        self.logger = logger
    }

    /// Leases `expectedUserID`'s token to the daemon, or ends the lease
    /// when nil. Returns once the daemon answered, so cloud reads that
    /// follow carry the lease. A failure clears the daemon's lease, so it
    /// never keeps a previous account's token. Work queued before is
    /// cancelled: this link supersedes it.
    func sync(_ sessions: any CloudLeaseSessions, expectedUserID: String?) async -> Outcome {
        let prior = leasing
        prior?.cancel()
        // task-owner: one token read and one cloud-session-set or -clear, after the previous lease work; ends with the reply
        let task = Task { [weak self] () -> Outcome in
            _ = await prior?.value
            guard let self else { return .superseded }
            return await lease(sessions, expectedUserID: expectedUserID, forceRefresh: false, clearOnFailure: true)
        }
        leasing = task
        return await task.value
    }

    /// A new lease for the account the cloud source acts as when the work
    /// runs (`expectedUserID`; nil: none, nothing to lease, `.signedOut`).
    /// The daemon asked (`cloud-session-needed`), or an op found no lease.
    /// `missing` takes the current token; the others need a refreshed one
    /// (an `expiring` token may still be the current one, which would only
    /// be asked for again). `finished` runs with the outcome once the work
    /// ends, so ops it refused can go again or the caller can retry. A
    /// failure leaves the daemon's lease as it was: that account's or none.
    func renew(_ sessions: any CloudLeaseSessions, reason: String, expectedUserID: @escaping @MainActor () -> String?,
               finished: @escaping @MainActor (Outcome) -> Void) {
        let prior = leasing
        // task-owner: one token read and one cloud-session-set, after the previous lease work; ends with the reply
        leasing = Task { [weak self] () -> Outcome in
            _ = await prior?.value
            guard let self else { return .superseded }
            guard let expected = expectedUserID() else {
                finished(.signedOut)
                return .signedOut
            }
            let outcome = await lease(sessions, expectedUserID: expected, forceRefresh: reason != "missing", clearOnFailure: false)
            finished(outcome)
            return outcome
        }
    }

    #if DEBUG
    /// Waits for the lease work started so far (tests).
    func settle() async {
        _ = await leasing?.value
    }
    #endif

    private func lease(_ sessions: any CloudLeaseSessions, expectedUserID: String?, forceRefresh: Bool,
                       clearOnFailure: Bool) async -> Outcome {
        do {
            guard let expectedUserID else {
                _ = try await sessions.clearSession()
                return .signedOut
            }
            guard tokens.isSignedIn else { throw Refusal.signedOut }
            let token = try await tokens.accessToken(forceRefresh: forceRefresh)
            try Task.checkCancellation()
            guard let origin = Self.origin(apiBaseURL) else { throw Refusal.noOrigin }
            // The token must be the account asked for: the user may have switched while it was read.
            guard let subject = Self.subject(ofJWT: token),
                  CloudIdentity.cloudID(stackUserID: subject) == CloudIdentity.cloudID(stackUserID: expectedUserID) else {
                throw Refusal.otherAccount
            }
            let expiresAt = Self.expiry(ofJWT: token) ?? Self.fallbackExpiry(now: Date())
            _ = try await sessions.setSession(CloudSessionSetRequest(apiBaseURL: origin, accessToken: token, expiresAt: expiresAt,
                                                                     clientVersion: clientVersion))
            return .leased(subject: subject, expiresAt: expiresAt)
        } catch is CancellationError {
            if clearOnFailure { _ = try? await sessions.clearSession() }
            return .superseded
        } catch {
            logger.error("cloud lease: \(String(describing: error), privacy: .public)")
            if clearOnFailure { _ = try? await sessions.clearSession() }
            return .failed
        }
    }

    /// The API origin: scheme, host and port only (the daemon refuses a path).
    nonisolated static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// No access token lives longer than this; a later `exp` is not trusted.
    nonisolated static let maxLifetime: TimeInterval = 30 * 24 * 3600

    /// The `exp` claim of a JWT access token, as Unix milliseconds. Read
    /// only to schedule the renewal; the daemon and the Worker verify it.
    /// A claim that is not finite, or later than `maxLifetime` from `now`,
    /// reads as missing (the lease then uses `fallbackExpiry`).
    nonisolated static func expiry(ofJWT token: String, now: Date = Date()) -> UInt64? {
        guard let claims = claims(ofJWT: token),
              let exp = (claims["exp"] as? NSNumber)?.doubleValue, exp.isFinite, exp > 0,
              exp <= now.timeIntervalSince1970 + maxLifetime else { return nil }
        return UInt64(exp * 1000)
    }

    /// The `sub` claim of a JWT access token: the Stack user id it was
    /// issued for. Read only to check that a lease is for the account asked
    /// for; the daemon and the Worker verify the token.
    nonisolated static func subject(ofJWT token: String) -> String? {
        guard let sub = claims(ofJWT: token)?["sub"] as? String, !sub.isEmpty else { return nil }
        return sub
    }

    /// The decoded payload of a JWT, unverified.
    nonisolated private static func claims(ofJWT token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var payload = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// A token without a readable `exp` is leased for five minutes, so the
    /// daemon asks again soon instead of trusting it for long.
    nonisolated static func fallbackExpiry(now: Date) -> UInt64 {
        UInt64((now.timeIntervalSince1970 + 300) * 1000)
    }
}
