import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxMobileTransport
import CmuxSettings
import CmuxTerminalCore
import CryptoKit
import Foundation
@preconcurrency import Network
import OSLog
import StackAuth
import os

enum MobileHostAuthorizationError: Error {
    case missingStackTokens
    case invalidStackUser
    case missingLocalUser
    case accountMismatch
    case verificationTimedOut
}
enum MobileHostAuthorizationPolicy {
    static func authorizeStackUserID(localUserID: String?, remoteUserID: String?) throws {
        guard let localUserID = normalizedUserID(localUserID) else {
            throw MobileHostAuthorizationError.missingLocalUser
        }
        guard normalizedUserID(remoteUserID) == localUserID else {
            throw MobileHostAuthorizationError.accountMismatch
        }
    }

    private static func normalizedUserID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

#if DEBUG
enum MobileHostDevStackAuthPolicy {
    static func normalizedToken(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    static func authorize(providedToken: String, acceptedToken: String?) -> Bool {
        guard let acceptedToken = normalizedToken(acceptedToken) else {
            return false
        }
        return normalizedToken(providedToken) == acceptedToken
    }
}
#endif

actor MobileHostStackAuthVerifier {
    static let shared = MobileHostStackAuthVerifier()
    private static let verificationTimeoutNanoseconds: UInt64 = 10 * 1_000_000_000

    private struct CacheEntry {
        let userID: String?
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var refreshingKeys: Set<String> = []
    private static let cacheTTLSeconds: TimeInterval = 60
    private static let refreshAheadWindowSeconds: TimeInterval = 15

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
        return (try? MobileHostAuthorizationPolicy.authorizeStackUserID(
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
        try MobileHostAuthorizationPolicy.authorizeStackUserID(
            localUserID: localUserID,
            remoteUserID: remoteUserID
        )
    }

    private func fetchAndCacheRemoteUserID(cacheKey: String, accessToken: String) async throws -> String? {
        // Primary path: verify the ES256 JWT locally against the project's
        // published JWKS — zero network once the key set is cached, which
        // takes session admission from a Stack round trip (~110-290ms) to
        // ~1ms. Opaque tokens and JWKS outages fall back to the legacy
        // /users/me check below; definitive signature/claim failures reject.
        if let localUserID = try await verifyLocallyIfPossible(accessToken: accessToken) {
            cache[cacheKey] = CacheEntry(
                userID: localUserID,
                expiresAt: Date().addingTimeInterval(Self.cacheTTLSeconds)
            )
            return localUserID
        }
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

    // MARK: Local JWKS verification

    private var jwksKeys: [StackAccessTokenJWT.JWK] = []
    private var jwksFetchedAt: Date = .distantPast
    private var jwksLastAttemptAt: Date = .distantPast
    private static let jwksTTLSeconds: TimeInterval = 24 * 60 * 60
    private static let jwksRefetchCooldownSeconds: TimeInterval = 60
    private static let jwksDefaultsKey = "mobile.stackJwks.v1"

    /// The persisted JWKS snapshot: the raw fetched key-set JSON plus its
    /// fetch time and source URL. Public signing keys only — tokens and
    /// verification verdicts are never persisted. Persisting the set lets the
    /// first admission after app launch verify locally instead of paying the
    /// ~110ms key fetch; the 24h TTL still applies from the persisted fetch
    /// time, and the URL check drops the snapshot when the configured Stack
    /// base URL or project changes.
    private struct PersistedJWKS: Codable {
        let url: String
        let fetchedAtEpochSeconds: Double
        let keySetJSON: Data
    }

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.jwksDefaultsKey),
              let persisted = try? JSONDecoder().decode(PersistedJWKS.self, from: data),
              persisted.url == Self.jwksURL().absoluteString,
              let decoded = try? JSONDecoder().decode(StackAccessTokenJWT.JWKS.self, from: persisted.keySetJSON),
              !decoded.keys.isEmpty else {
            return
        }
        jwksKeys = decoded.keys
        jwksFetchedAt = Date(timeIntervalSince1970: persisted.fetchedAtEpochSeconds)
    }

    private static func jwksURL() -> URL {
        AuthEnvironment.stackBaseURL
            .appendingPathComponent("api/v1/projects/\(AuthEnvironment.stackProjectID)/.well-known/jwks.json")
    }

    private static func persistJWKS(keySetJSON: Data, fetchedAt: Date, url: URL) {
        let persisted = PersistedJWKS(
            url: url.absoluteString,
            fetchedAtEpochSeconds: fetchedAt.timeIntervalSince1970,
            keySetJSON: keySetJSON
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        UserDefaults.standard.set(data, forKey: jwksDefaultsKey)
    }

    /// The token's verified user id via the local JWKS path, `nil` when this
    /// token cannot be verified locally (opaque format, or no key set is
    /// obtainable) so the caller falls back to the network check. Definitive
    /// verification failures throw.
    private func verifyLocallyIfPossible(accessToken: String) async throws -> String? {
        var keys = await loadJWKSIfNeeded(force: false)
        guard !keys.isEmpty else { return nil }
        let projectID = AuthEnvironment.stackProjectID
        // Issuer allow-set derived from the configured Stack base URL (plus
        // its rebrand alias host); an iss mismatch is a definitive reject.
        let allowedIssuers = StackAccessTokenJWT.allowedIssuers(
            stackAPIBaseURL: AuthEnvironment.stackBaseURL,
            projectID: projectID
        )
        for attempt in 0..<2 {
            do {
                return try StackAccessTokenJWT.verifiedUserID(
                    token: accessToken,
                    keys: keys,
                    projectID: projectID,
                    allowedIssuers: allowedIssuers
                )
            } catch StackAccessTokenJWT.VerificationError.notAJWT {
                return nil
            } catch StackAccessTokenJWT.VerificationError.unknownKeyID {
                // Key rotation: refetch once (cooldown-limited), then a still
                // unknown kid is definitive.
                guard attempt == 0 else { throw MobileHostAuthorizationError.invalidStackUser }
                let refreshed = await loadJWKSIfNeeded(force: true)
                guard !refreshed.isEmpty else { return nil }
                keys = refreshed
            } catch {
                throw MobileHostAuthorizationError.invalidStackUser
            }
        }
        return nil
    }

    private func loadJWKSIfNeeded(force: Bool) async -> [StackAccessTokenJWT.JWK] {
        let now = Date()
        let fresh = now.timeIntervalSince(jwksFetchedAt) < Self.jwksTTLSeconds
        if !jwksKeys.isEmpty, fresh, !force { return jwksKeys }
        guard now.timeIntervalSince(jwksLastAttemptAt) >= Self.jwksRefetchCooldownSeconds
                || (jwksKeys.isEmpty && jwksLastAttemptAt == .distantPast) else {
            return jwksKeys
        }
        jwksLastAttemptAt = now
        let url = Self.jwksURL()
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(StackAccessTokenJWT.JWKS.self, from: data),
              !decoded.keys.isEmpty else {
            return jwksKeys
        }
        jwksKeys = decoded.keys
        jwksFetchedAt = now
        Self.persistJWKS(keySetJSON: data, fetchedAt: now, url: url)
        return jwksKeys
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

    private func currentAuthenticatedLocalUserID() async -> String? {
        await MobileHostService.shared.currentAuthenticatedLocalUserID()
    }
}

private actor MobileHostAccessTokenStore: TokenStoreProtocol {
    private var accessToken: String?

    init(accessToken: String) {
        self.accessToken = accessToken
    }

    func getStoredAccessToken() async -> String? {
        accessToken
    }

    func getStoredRefreshToken() async -> String? {
        nil
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        if let accessToken {
            self.accessToken = accessToken
        }
    }

    func clearTokens() async {
        accessToken = nil
    }

    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        if let newAccessToken {
            accessToken = newAccessToken
        }
    }
}

actor MobileHostSerializedTransportWriter {
    private let transport: any CmxByteTransport
    private var sending = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(transport: any CmxByteTransport) {
        self.transport = transport
    }

    func send(_ data: Data) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await transport.send(data)
    }

    private func acquire() async {
        if !sending {
            sending = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            sending = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
