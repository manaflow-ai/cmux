public import CmuxUpdater
public import Foundation

/// What picking a slower ring (Dev to Nightly) does to the build this Mac runs. Sparkle never
/// offers a lower build, so when the running build is not on the ring and the ring has no update
/// for it (none newer, or the newest held by the staged rollout), the way back is the newest build of that ring this Mac kept (a rollback swap: one
/// restart, the same settings and sessions); with none kept, the running build stays until the
/// ring reaches a newer one.
nonisolated public enum RingReturn: Equatable, Sendable {
    /// The running build is on the ring, or Sparkle would update it from the ring (a newer build this
    /// macOS runs that this install's staged rollout reaches): the normal update path.
    case none
    /// Restart into this kept build, the newest one on the ring.
    case goBack(KeptVersion)
    /// Nothing kept on the ring: the running build stays until the ring passes it.
    case waits

    /// - Parameters:
    ///   - installedBuild: the running build.
    ///   - offered: the feed's items the ring sees.
    ///   - promoted: builds the canary passed; on the Nightly ring these count as its own even
    ///     after they leave the feed.
    ///   - pulled: builds on the feed's pulled list: never a way back, whatever their verdict.
    ///   - kept: kept versions, newest first.
    ///   - rollout: this install's staged rollout; nil offers every item.
    ///   - system: this Mac's macOS, which Sparkle filters items by.
    public static func decide(installedBuild: String, offered: [AppcastItem], promoted: Set<String>,
                              pulled: Set<String> = [], kept: [KeptVersion], rollout: StagedRollout? = nil,
                              system: SystemVersion = .current) -> RingReturn {
        let onRing = Set(offered.map(\.version)).union(promoted).subtracting(pulled)
        if onRing.contains(installedBuild) { return .none }
        // The way forward is the update Sparkle would take here (the newest item this macOS runs, held
        // when this install's staged rollout does not reach it): the probe's own rule.
        if case .updateAvailable = UpdateProber.outcome(offered, currentBuild: installedBuild, system: system, rollout: rollout) {
            return .none
        }
        // A build the ring holds for this install (halted, or not yet at its stage) is no way back.
        let held = Set(offered.filter { rollout?.offers(version: $0.version, rawPercent: $0.rolloutPercent) == false }.map(\.version))
        guard let target = kept.first(where: { onRing.contains($0.build) && !held.contains($0.build)
                                             && AppcastSelector.isOlder($0.build, than: installedBuild) })
        else { return .waits }
        return .goBack(target)
    }
}
