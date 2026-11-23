import Foundation

/// A thing a screen holds for a tab (a terminal host, a page) goes when its tab is missing from
/// the Mac's list. A link drop and relink can publish a workspace with tabs missing for a few
/// seconds, so the tab must stay missing on a connected Mac past `grace` first (the same idea as
/// the tab selection's hold). While the link is down the clock does not run.
public struct MissingGrace<ID: Hashable & Sendable>: Sendable {
    public static var defaultGrace: Duration { .seconds(10) }

    private var since: [ID: ContinuousClock.Instant] = [:]

    public init() {}

    /// Which of `held` to let go now. `present`: the ids the Mac lists. `linkUp`: the Mac is
    /// connected. Ids listed again, or seen while the link is down, start their grace over.
    public mutating func expired(held: some Collection<ID>, present: Set<ID>, linkUp: Bool,
                                 now: ContinuousClock.Instant = .now, grace: Duration = defaultGrace) -> [ID] {
        var gone: [ID] = []
        var keep: [ID: ContinuousClock.Instant] = [:]
        for id in held where !present.contains(id) {
            guard linkUp else { continue }
            let first = since[id] ?? now
            if now - first >= grace { gone.append(id) } else { keep[id] = first }
        }
        since = keep
        return gone
    }
}
