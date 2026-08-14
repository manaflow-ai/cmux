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
