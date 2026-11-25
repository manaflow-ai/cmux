public import Foundation
import CmuxNextWindowRules

/// What picking a slower ring (Dev to Nightly) does to the build this Mac runs. Sparkle never
/// offers a lower build, so when the running build is not on the ring and the ring has nothing
/// newer, the way back is the newest build of that ring this Mac kept (a rollback swap: one
/// restart, the same settings and sessions); with none kept, the running build stays until the
/// ring reaches a newer one. The rule is cmux-updater-core's (`rollback.rs` `ring_return`), asked
/// over the app FFI (`updater_ring_return`).
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
        struct Request: Encodable { var installedBuild: String; var offered, promoted, pulled, kept: [String] }
        struct Reply: Decodable { var kind: String; var kept: Int? }
        let request = Request(installedBuild: installedBuild, offered: offered.map(\.version), promoted: promoted.sorted(),
                              pulled: pulled.sorted(), kept: kept.map(\.build))
        // A build whose FFI lacks the op leaves the running build where it is.
        guard let reply = WindowRules().call("updater_ring_return", request, as: Reply.self) else { return .none }
        switch reply.kind {
        case "goBack": return reply.kept.flatMap { kept.indices.contains($0) ? .goBack(kept[$0]) : nil } ?? .waits
        case "waits": return .waits
        default: return .none
        }
    }
}
