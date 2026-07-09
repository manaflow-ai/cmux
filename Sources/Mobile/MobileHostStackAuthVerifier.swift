import CMUXMobileCore
import CryptoKit
import Foundation
import StackAuth

/// Same-account Stack-token verifier for the mobile data plane: a short-TTL
/// cache of verified access-token → Stack-user bindings with refresh-ahead, so
/// an actively-typing client never blocks a keystroke on the Stack network
/// round trip.
///
/// De-singletonized from `MobileHostService`: the owner constructs and holds
/// one instance and injects the local-user lookup, so the verifier never
/// reaches back into app-global state to decide same-account authorization.
actor MobileHostStackAuthVerifier {
    private static let verificationTimeoutNanoseconds: UInt64 = 10 * 1_000_000_000

    private struct CacheEntry {
        let userID: String?
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var refreshingKeys: Set<String> = []
    private static let cacheTTLSeconds: TimeInterval = 60
    private static let refreshAheadWindowSeconds: TimeInterval = 15

    /// Resolves this Mac's signed-in local user id (awaiting auth bootstrap),
    /// injected by the owner so the verifier stays decoupled from the app's
    /// auth singleton.
    private let currentAuthenticatedLocalUserID: @Sendable () async -> String?

    /// - Parameter currentAuthenticatedLocalUserID: The owner-supplied lookup
    ///   for this Mac's signed-in local user id, used to decide same-account
    ///   authorization against a verified remote Stack user id.
    init(currentAuthenticatedLocalUserID: @escaping @Sendable () async -> String?) {
        self.currentAuthenticatedLocalUserID = currentAuthenticatedLocalUserID
    }

    /// The verification verdict for `auth`'s token using only the cache, or
    /// `nil` when no fresh cached binding exists (deciding would need a Stack
    /// network lookup). Lets the unauthenticated status path answer
    /// already-verified callers without spending a capped network slot.
    func cachedVerdict(auth: MobileHostRPCAuth?) async -> Bool? {
        guard let accessToken = auth?.stackAccessToken else {
            return false
        }
        guard let cached = cache[Self.cacheKey(for: accessToken)],
              cached.expiresAt > Date() else {
            return nil
        }
        let localUserID = await currentAuthenticatedLocalUserID()
        return (try? MobileHostAuthorizationPolicy().authorizeStackUserID(
            localUserID: localUserID,
            remoteUserID: cached.userID
        )) != nil
    }

    func verify(auth: MobileHostRPCAuth?) async throws {
        guard let accessToken = auth?.stackAccessToken else {
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

        let localUserID = await currentAuthenticatedLocalUserID()
        try MobileHostAuthorizationPolicy().authorizeStackUserID(
            localUserID: localUserID,
            remoteUserID: remoteUserID
        )
    }

    private func fetchAndCacheRemoteUserID(cacheKey: String, accessToken: String) async throws -> String? {
        let stack = Self.makeStackClient(accessToken: accessToken)
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

    private static func makeStackClient(accessToken: String) -> StackClientApp {
        StackClientApp(
            projectId: AuthEnvironment.stackProjectID,
            publishableClientKey: AuthEnvironment.stackPublishableClientKey,
            baseUrl: AuthEnvironment.stackBaseURL.absoluteString,
            tokenStore: .custom(MobileHostAccessTokenStore(accessToken: accessToken)),
            noAutomaticPrefetch: true
        )
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
