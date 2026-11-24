// DEBUG and Demo builds only: the list rig's apply probe (verify/listperf/).
#if DEBUG
import Foundation

/// Tells the list rig each time a live list applies a change to its rows (the Workspaces and Feed
/// collections), so it can count applies per second and how long a store write waited for one.
@MainActor
public final class ListApplyProbe {
    public static let shared = ListApplyProbe()

    /// Set by the rig; nil (no cost but the check) otherwise.
    public var onApply: (@MainActor (_ list: String) -> Void)?

    /// The rig scrolls the lists from code, which sets no dragging flag: while it runs, a list
    /// that moved in the last few frames counts as scrolling.
    public var codeDrivenScroll = false

    public init() {}

    public func applied(_ list: String) {
        onApply?(list)
    }

    /// Named counts the list rig logs once a second and resets (cells configured, heights
    /// measured, inbox builds and updates, list body passes): what each live tick costs.
    public private(set) var counts: [String: Int] = [:]
    /// Set by the rig: the counts are kept only while it measures.
    public var counting = false

    public func count(_ name: String, _ by: Int = 1) {
        guard counting else { return }
        counts[name, default: 0] += by
    }

    /// The counts so far, then zero.
    public func takeCounts() -> [String: Int] {
        defer { counts = [:] }
        return counts
    }

    /// Set by the rig: one slow apply's details (the list, its ms and what it did).
    public var onSlowApply: (@MainActor (_ line: String) -> Void)?
}
#endif
