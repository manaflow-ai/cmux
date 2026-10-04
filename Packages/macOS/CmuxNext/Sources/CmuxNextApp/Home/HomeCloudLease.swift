import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import os

/// The cloud session lease the app gives the local daemon
/// (home-cloud-proxy.md section 2). CloudAuth (the signed-in trusted local
/// client) owns the Stack session; the daemon holds the current access token
/// in memory only and asks for a new one with `cloud-session-needed`.
@MainActor
final class HomeCloudLease {
    private let auth: CloudAuth
    private let apiBaseURL: URL
    private let clientVersion: String?
    private let logger: Logger
    private var leasing: Task<Void, Never>?

    init(auth: CloudAuth, apiBaseURL: URL, clientVersion: String?, logger: Logger) {
        self.auth = auth
        self.apiBaseURL = apiBaseURL
        self.clientVersion = clientVersion
        self.logger = logger
    }

    /// Leases the current token to `connection` while signed in, and ends
    /// the lease when signed out. Returns once the daemon answered, so
    /// cloud reads that follow carry the lease.
    func sync(_ connection: DaemonConnection) async {
        leasing?.cancel()
        await lease(connection, forceRefresh: false)
    }

    /// The daemon asked for a lease. `missing` takes the current token; the
    /// others need a refreshed one (an `expiring` token may still be the
    /// current one, which would only be asked for again). `leased` runs once
    /// the daemon holds the new lease, so ops it refused can go again.
    func renew(_ connection: DaemonConnection, reason: String, leased: @escaping @MainActor () -> Void) {
        leasing?.cancel()
        // task-owner: one token read and one cloud-session-set; ends with the reply
        leasing = Task { [weak self] in
            if await self?.lease(connection, forceRefresh: reason != "missing") == true { leased() }
        }
    }

    /// Returns whether the daemon now holds a lease.
    @discardableResult
    private func lease(_ connection: DaemonConnection, forceRefresh: Bool) async -> Bool {
        let client = CloudConversationClient(connection)
        do {
            guard auth.isSignedIn else {
                _ = try await client.clearSession()
                return false
            }
            let token = forceRefresh ? try await auth.coordinator.forceRefreshAccessToken() : try await auth.tokens().access
            guard !Task.isCancelled, let origin = Self.origin(apiBaseURL) else { return false }
            let expiresAt = Self.expiry(ofJWT: token) ?? Self.fallbackExpiry(now: Date())
            _ = try await client.setSession(CloudSessionSetRequest(apiBaseURL: origin, accessToken: token, expiresAt: expiresAt,
                                                                   clientVersion: clientVersion))
            return true
        } catch is CancellationError {
            return false
        } catch {
            logger.error("cloud lease: \(String(describing: error), privacy: .public)")
            return false
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
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var payload = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (claims["exp"] as? NSNumber)?.doubleValue, exp.isFinite, exp > 0,
              exp <= now.timeIntervalSince1970 + maxLifetime else { return nil }
        return UInt64(exp * 1000)
    }

    /// A token without a readable `exp` is leased for five minutes, so the
    /// daemon asks again soon instead of trusting it for long.
    nonisolated static func fallbackExpiry(now: Date) -> UInt64 {
        UInt64((now.timeIntervalSince1970 + 300) * 1000)
    }
}
