public import Foundation

/// What picking a slower ring (Dev to Nightly) does to the build this Mac runs. Sparkle never
/// offers a lower build, so when the running build is not on the ring and the ring has nothing
/// newer, the way back is the newest build of that ring this Mac kept (a rollback swap: one
/// restart, the same settings and sessions); with none kept, the running build stays until the
/// ring reaches a newer one.
nonisolated public enum RingReturn: Equatable, Sendable {
    /// The running build is on the ring, or the ring offers a newer one: the normal update path.
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
    public static func decide(installedBuild: String, offered: [AppcastItem], promoted: Set<String>,
                              pulled: Set<String> = [], kept: [KeptVersion]) -> RingReturn {
        let onRing = Set(offered.map(\.version)).union(promoted).subtracting(pulled)
        if onRing.contains(installedBuild) { return .none }
        if offered.contains(where: { AppcastSelector.isOlder(installedBuild, than: $0.version) }) { return .none }
        guard let target = kept.first(where: { onRing.contains($0.build) && AppcastSelector.isOlder($0.build, than: installedBuild) })
        else { return .waits }
        return .goBack(target)
    }
}
