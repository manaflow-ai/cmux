import Foundation

/// Tracks which agent sessions have already had a resume command launched
/// very recently, so that two panels referencing the same underlying agent
/// session — a duplicate-workspace restore, a restore-into-live, or two
/// panels in the same restore pass — never both fire `codex resume <id>` /
/// `claude --resume <id>` concurrently (#8446).
///
/// A claim expires after `claimTTL`. It exists only to break the tie between
/// two `createPanel` calls that both run before either spawned process is
/// visible in `SharedLiveAgentIndex` — once that index catches up (or the
/// claiming panel's launch never actually happens, e.g. the tab is closed
/// and the agent exits), liveness should once again be judged purely by the
/// live-process index. A permanent, never-expiring claim would otherwise
/// block a legitimate resume the next time the same session is restored
/// (e.g. reopening a closed tab well after the original agent exited).
@MainActor
final class AgentResumeLaunchGuard {
    static let shared = AgentResumeLaunchGuard()

    private static let claimTTL: TimeInterval = 60

    private var claimedSessionKeys: [String: Date] = [:]
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
        let key = Self.key(kind: kind, sessionId: sessionId)
        let now = dateProvider()
        if let claimedAt = claimedSessionKeys[key], now.timeIntervalSince(claimedAt) < Self.claimTTL {
            return false
        }
        claimedSessionKeys[key] = now
        return true
    }

    private static func key(kind: String, sessionId: String) -> String {
        "\(kind)\u{1f}\(sessionId)"
    }
}
