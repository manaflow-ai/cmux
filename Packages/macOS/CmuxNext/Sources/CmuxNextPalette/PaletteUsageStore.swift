public import Foundation

/// Where the palette's usage history lives (plans/cmux-next/palette-ranking.md
/// 5.3). The app's store is the daemon's `palette-usage-v1` history, one
/// writer for every client; this side keeps a read mirror and sends uses.
@MainActor
public protocol PaletteUsageStore: AnyObject {
    /// The history the ranker reads (a mirror for the daemon's store).
    var history: FrecencyStore { get }
    /// Runs when `history` changes outside a `recordUse` call (a fetch).
    var onChange: (@MainActor () -> Void)? { get set }
    /// One run of row `key` for `query` ("" for an empty query).
    func recordUse(key: String, query: String, at now: Date)
    /// The palette is about to open: refresh the mirror if it is stale.
    func prepare()
    /// The store can hide rows (the daemon's history; a local history cannot).
    var canHideRows: Bool { get }
    /// Hides row `key` from the palette, or shows it again.
    func setHidden(key: String, hidden: Bool)
    /// Reset Ranking: forgets row `key`'s uses and learned picks.
    func forget(key: String)
}

/// A history kept in this process and saved with `persistence` (tests, and
/// an older daemon without `palette-usage-v1`). It has no learned picks.
@MainActor
public final class LocalPaletteUsageStore: PaletteUsageStore {
    public private(set) var history: FrecencyStore
    public var onChange: (@MainActor () -> Void)?
    private let persistence: (any FrecencyPersisting)?

    public init(history: FrecencyStore? = nil, persistence: (any FrecencyPersisting)?) {
        self.persistence = persistence
        self.history = history ?? persistence?.load() ?? FrecencyStore()
    }

    public func recordUse(key: String, query: String, at now: Date) {
        history.record(key, at: now)
        persistence?.save(history)
    }

    public func prepare() {}

    public var canHideRows: Bool { false }

    public func setHidden(key: String, hidden: Bool) {}

    public func forget(key: String) {
        history.forget(key)
        persistence?.save(history)
    }
}
