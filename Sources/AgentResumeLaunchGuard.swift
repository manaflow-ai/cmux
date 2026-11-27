import Foundation

/// Claims in-flight launches by the same canonical identity used by the Vault.
///
/// Local restores claim at the pre-exec socket boundary; compatibility launches
/// that cannot use that boundary claim before their command is admitted. This
/// closes the visibility gap before a new process reaches the live-agent index.
///
/// A claim expires after `claimTTL`. It exists only to break the tie between
/// two launch requests that both run before either spawned process is visible
/// in `SharedLiveAgentIndex` — once that index catches up (or the
/// claiming panel's launch never actually happens, e.g. the tab is closed
/// and the agent exits), liveness should once again be judged purely by the
/// live-process index. A permanent, never-expiring claim would otherwise
/// block a legitimate resume the next time the same session is restored
/// (e.g. reopening a closed tab well after the original agent exited).
@MainActor
final class AgentResumeLaunchGuard {
    nonisolated struct Claim: Equatable, Sendable {
        let id: UUID
    }

    static let shared = AgentResumeLaunchGuard()

    private static let claimTTL: TimeInterval = 60

    /// Internal (not `private`) so tests can assert on eviction behavior via
    /// `@testable import` instead of a dedicated debug-only accessor.
    var claimedSessionKeys: [String: Date] = [:]
    private var claimIDsBySessionKey: [String: UUID] = [:]
    private let dateProvider: () -> Date

    init(dateProvider: @escaping () -> Date = Date.init) {
        self.dateProvider = dateProvider
    }

    /// Attempts to claim the resume launch for `(kind, sessionId)`.
    ///
    /// Returns `true` the first time a given session is claimed (or once a
    /// prior claim has expired), meaning the caller should proceed with
    /// firing the resume. Returns `false` while an unexpired claim for the
    /// same session is already held, meaning some other panel already
    /// claimed it and the caller must skip firing a duplicate resume.
    @discardableResult
    func claimResumeLaunch(kind: String, sessionId: String) -> Bool {
        claimResumeLaunchWithToken(kind: kind, sessionId: sessionId) != nil
    }

    /// Claims a launch and returns the identity required for scoped release.
    func claimResumeLaunchWithToken(kind: String, sessionId: String) -> Claim? {
        let key = Self.key(kind: kind, sessionId: sessionId)
        let now = dateProvider()
        pruneExpiredClaims(now: now)
        if let claimedAt = claimedSessionKeys[key], now.timeIntervalSince(claimedAt) < Self.claimTTL {
            return nil
        }
        let claim = Claim(id: UUID())
        claimedSessionKeys[key] = now
        claimIDsBySessionKey[key] = claim.id
        return claim
    }

    /// Releases a claim early, before its TTL elapses, when the caller
    /// discovers its own launch never actually happened (e.g. terminal
    /// surface creation failed after the claim was taken). Safe to call for
    /// a key that was never claimed or already expired.
    func releaseResumeLaunch(kind: String, sessionId: String) {
        let key = Self.key(kind: kind, sessionId: sessionId)
        claimedSessionKeys.removeValue(forKey: key)
        claimIDsBySessionKey.removeValue(forKey: key)
    }

    /// Releases only the launch that received `claim`, never a newer claimant.
    @discardableResult
    func releaseResumeLaunch(
        kind: String,
        sessionId: String,
        claim: Claim
    ) -> Bool {
        let key = Self.key(kind: kind, sessionId: sessionId)
        guard claimIDsBySessionKey[key] == claim.id else { return false }
        claimedSessionKeys.removeValue(forKey: key)
        claimIDsBySessionKey.removeValue(forKey: key)
        return true
    }

    /// Bounds `claimedSessionKeys` growth over a long-running app process:
    /// every distinct session ever resumed would otherwise leave a permanent
    /// dictionary entry.
    private func pruneExpiredClaims(now: Date) {
        claimedSessionKeys = claimedSessionKeys.filter { now.timeIntervalSince($0.value) < Self.claimTTL }
        claimIDsBySessionKey = claimIDsBySessionKey.filter { claimedSessionKeys[$0.key] != nil }
    }

    private static func key(kind: String, sessionId: String) -> String {
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(normalizedKind)\u{1f}" + ManagedAgentSessionIdentity.canonicalSessionID(
            kind: normalizedKind,
            sessionID: sessionId
        )
    }
}
