import CMUXMobileCore
import CryptoKit
import Foundation
public import StackAuth

/// Verifies that a mobile-host client's Stack access token belongs to the same
/// account that is signed in on this Mac, with a short-lived cache and
/// refresh-ahead so the verification stays off the per-keystroke critical path.
///
/// Every authorized mobile RPC (down to `terminal.input`) flows through
/// ``verify(stackAccessToken:)``; the unauthenticated status verb uses
/// ``cachedVerdict(stackAccessToken:)`` to answer already-verified callers
/// without spending a capped network slot. A cache miss resolves the remote
/// user by asking Stack who owns the presented token, under a 10s timeout, then
/// authorizes it against the Mac owner via ``MobileHostAccountAuthorizer``.
///
/// App coupling is constructor-injected so the verifier is self-contained:
/// ``localUserIDProvider`` returns the signed-in local user id (the app reads
/// its auth graph), and ``makeStackClient`` builds a `StackClientApp` for a
/// presented access token (the app supplies the Stack project credentials).
/// The verifier owns the verification cache, the refresh-ahead bookkeeping, the
/// SHA256 cache-key derivation, and the timeout TaskGroup. The app constructs
/// one instance at the composition root and holds it; there is no `shared`
/// singleton.
public actor MobileHostStackAuthVerifier {
    private static let verificationTimeoutNanoseconds: UInt64 = 10 * 1_000_000_000

    private struct CacheEntry {
        let userID: String?
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var refreshingKeys: Set<String> = []
    private static let cacheTTLSeconds: TimeInterval = 60
    private static let refreshAheadWindowSeconds: TimeInterval = 15

    /// Resolves the signed-in local user id (or `nil` when signed out / before
    /// the auth graph is ready). Injected so the package does not reach back into
    /// the app's `MobileHostService`.
    private let localUserIDProvider: @Sendable () async -> String?
    /// Builds a `StackClientApp` seeded with the presented access token. Injected
    /// so the Stack project credentials (read from the app's `AuthEnvironment`)
    /// stay app-side; production passes a closure that wraps the token in a
    /// ``MobileHostAccessTokenStore``.
    private let makeStackClient: @Sendable (_ accessToken: String) -> StackClientApp

    /// Creates a verifier.
    ///
    /// - Parameters:
    ///   - localUserIDProvider: Returns the local Mac owner's user id, or `nil`
    ///     when signed out or before auth is configured.
    ///   - makeStackClient: Builds a `StackClientApp` for a presented access
    ///     token used to resolve the remote Stack user.
    public init(
        localUserIDProvider: @escaping @Sendable () async -> String?,
        makeStackClient: @escaping @Sendable (_ accessToken: String) -> StackClientApp
    ) {
        self.localUserIDProvider = localUserIDProvider
        self.makeStackClient = makeStackClient
    }

    /// The verification verdict for the token using only the cache, or `nil` when
    /// no fresh cached binding exists (deciding would need a Stack network
    /// lookup). Lets the unauthenticated status path answer already-verified
    /// callers without spending a capped network slot.
    public func cachedVerdict(stackAccessToken: String?) async -> Bool? {
        guard let accessToken = stackAccessToken else {
            return false
        }
        guard let cached = cache[Self.cacheKey(for: accessToken)],
              cached.expiresAt > Date() else {
            return nil
        }
        let localUserID = await localUserIDProvider()
        return (try? MobileHostAccountAuthorizer().authorizeStackUserID(
            localUserID: localUserID,
            remoteUserID: cached.userID
        )) != nil
    }

    /// Throws unless the presented Stack access token resolves to the same
    /// account signed in on this Mac.
    public func verify(stackAccessToken: String?) async throws {
        guard let accessToken = stackAccessToken else {
            throw MobileHostAuthorizationError.missingStackTokens
        }

        let cacheKey = Self.cacheKey(for: accessToken)
        let now = Date()
        let remoteUserID: String?
        cache = cache.filter { $0.value.expiresAt > now }
        if let cached = cache[cacheKey], cached.expiresAt > now {
            remoteUserID = cached.userID
            // Refresh-ahead: when the cached binding is near expiry, re-verify in
            // the background so an actively-typing client never blocks a keystroke
            // on the network round-trip. Every mobile request now requires Stack
            // auth, so the verification must stay off the critical path.
            if cached.expiresAt.timeIntervalSince(now) < Self.refreshAheadWindowSeconds {
                scheduleRefreshAhead(cacheKey: cacheKey, accessToken: accessToken)
            }
        } else {
            remoteUserID = try await fetchAndCacheRemoteUserID(cacheKey: cacheKey, accessToken: accessToken)
        }

        let localUserID = await localUserIDProvider()
        try MobileHostAccountAuthorizer().authorizeStackUserID(
            localUserID: localUserID,
            remoteUserID: remoteUserID
        )
    }

    private func fetchAndCacheRemoteUserID(cacheKey: String, accessToken: String) async throws -> String? {
        let stack = makeStackClient(accessToken)
        guard let user = try await Self.withVerificationTimeout({
            try await stack.getUser(or: .throw)
        }) else {
            throw MobileHostAuthorizationError.invalidStackUser
        }
        let remoteUserID = await user.id
        cache[cacheKey] = CacheEntry(
            userID: remoteUserID,
            expiresAt: Date().addingTimeInterval(Self.cacheTTLSeconds)
        )
        return remoteUserID
    }

    private func scheduleRefreshAhead(cacheKey: String, accessToken: String) {
        guard !refreshingKeys.contains(cacheKey) else { return }
        refreshingKeys.insert(cacheKey)
        Task { await self.refreshAhead(cacheKey: cacheKey, accessToken: accessToken) }
    }

    private func refreshAhead(cacheKey: String, accessToken: String) async {
        defer { refreshingKeys.remove(cacheKey) }
        // Best-effort: on failure leave the existing entry to expire naturally.
        _ = try? await fetchAndCacheRemoteUserID(cacheKey: cacheKey, accessToken: accessToken)
    }

    private static func cacheKey(for accessToken: String) -> String {
        // Pure-Swift byte-to-hex (no String(format:)) — this runs for every
        // authorized mobile RPC (incl. per-keystroke terminal.input) before the
        // verifier cache hit, so it must stay allocation-cheap. String(format:)
        // here would reintroduce the PR #5347 hot-path memory-growth crash class.
        let digest = Array(SHA256.hash(data: Data(accessToken.utf8)))
        let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
        var hex = [UInt8]()
        hex.reserveCapacity(digest.count * 2)
        for byte in digest {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }

    private static func withVerificationTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: verificationTimeoutNanoseconds)
                throw MobileHostAuthorizationError.verificationTimedOut
            }

            guard let value = try await group.next() else {
                throw MobileHostAuthorizationError.verificationTimedOut
            }
            group.cancelAll()
            return value
        }
    }
}
