public import Foundation
import CmuxNextWindowRules

/// Picks what a feed offers, by Sparkle's rules: an item is offered only when
/// `minimumSystemVersion <= macOS <= maximumSystemVersion`, and the newest offered item (by
/// Sparkle 2's `SUStandardVersionComparator` order) wins. The rules and the order are
/// cmux-updater-core's (`select.rs`, `version.rs`), asked over the app FFI
/// (`updater_appcast_select`, `updater_version_compare`).
nonisolated public enum AppcastSelector {
    public static func select(from items: [AppcastItem], currentBuild: String, system: SystemVersion) -> UpdateProbeOutcome {
        let request = SelectRequest(
            items: items.map { Candidate(version: $0.version, minimumSystemVersion: $0.minimumSystemVersion.map(WireSystemVersion.init),
                                         maximumSystemVersion: $0.maximumSystemVersion.map(WireSystemVersion.init)) },
            currentBuild: currentBuild, system: WireSystemVersion(system))
        // The core always answers a well-formed request; a build whose FFI lacks the op offers nothing.
        guard let reply = WindowRules().call("updater_appcast_select", request, as: SelectReply.self) else {
            return .upToDate(latest: nil)
        }
        let item = reply.item.flatMap { items.indices.contains($0) ? items[$0] : nil }
        switch reply.kind {
        case "update_available":
            if let item { return .updateAvailable(item) }
        case "requires_newer_macos":
            if let item { return .requiresNewerSystem(item, required: reply.required?.version ?? system) }
        default:
            break
        }
        return .upToDate(latest: reply.latest.flatMap { items.indices.contains($0) ? items[$0] : nil })
    }

    /// Sparkle's ordering of `CFBundleVersion` strings.
    public static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    /// How `lhs` orders against `rhs` in Sparkle's order. A build whose FFI lacks the op calls
    /// them equal, so nothing installs or rolls back on a guess.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let reply = WindowRules().call("updater_version_compare", CompareRequest(pairs: [[lhs, rhs]]), as: CompareReply.self),
              let order = reply.orders.first else { return .orderedSame }
        return order < 0 ? .orderedAscending : order > 0 ? .orderedDescending : .orderedSame
    }

    private struct Candidate: Encodable {
        var version: String
        var minimumSystemVersion: WireSystemVersion?
        var maximumSystemVersion: WireSystemVersion?
    }

    private struct SelectRequest: Encodable {
        var items: [Candidate]
        var currentBuild: String
        var system: WireSystemVersion
    }

    private struct SelectReply: Decodable {
        var kind: String
        var item: Int?
        var latest: Int?
        var required: WireSystemVersion?
    }

    private struct CompareRequest: Encodable { var pairs: [[String]] }
    private struct CompareReply: Decodable { var orders: [Int] }
}
