/// How many pages the New Tab spare pool keeps (CmuxNextApp's `NewTabSparePool`; decision 2026-11-16): as many as
/// the opens of the last ``burst`` asked for, ``most`` at most, until ``release`` passed with no open; then the
/// pool's own count again (``floor``: one page).
///
/// One page serves someone who opens a tab or a chat now and then: the next page is there before the next open.
/// Someone who opens three chats in a row finds a page for the first only, and every page the pool keeps is a
/// renderer and an acpmux client at idle. So the pool grows with a burst and gives the pages back after it.
///
/// A pure value: the caller gives the time (``AgentPaneSpareRefiller`` reads its clock) and applies the size.
///
/// ```swift
/// var demand = AgentPaneSpareDemand()
/// demand.asked(at: now)        // 1, then 2, then 3 for three opens in one second
/// demand.released(at: later)   // 1 once 60 s passed with no open; nil before
/// ```
public nonisolated struct AgentPaneSpareDemand: Equatable, Sendable {
    /// The most pages a burst raises the pool to. Three: a row of sidebar clicks or of Cmd-T seldom asks for more
    /// before the first refill lands, and each page is a renderer and an acpmux client until the release.
    public static let most = 3
    /// Opens this close together are one burst.
    public static let burst: Duration = .seconds(1)
    /// With no open for this long the pool is back to ``floor``: the burst is over, and its pages are memory that
    /// serves nobody.
    public static let release: Duration = .seconds(60)

    /// The pool's own count, which the rule never goes below: one page (`debug.new_tab capacity` raises it).
    public var floor: Int { didSet { floor = max(1, floor) } }
    /// The pages the bursts since the last release asked for.
    public private(set) var grown = 1
    /// When the latest opens asked, ``most`` of them at most, the last one last.
    private var asks: [Duration] = []

    /// - Parameter floor: The pool's own count (one page at least).
    public init(floor: Int = 1) {
        self.floor = max(1, floor)
    }

    /// The pages the pool keeps now.
    public var size: Int { max(floor, grown) }
    /// Whether a burst raised the count: a release is due ``release`` after the last open.
    public var isGrown: Bool { grown > 1 }

    /// An open asked the pool for a page at `now`. It counts also when the pool had no page for it: a pool of one
    /// hands out one page in a burst, so it would never grow by its handouts.
    /// - Returns: The pages the pool keeps from now on.
    @discardableResult
    public mutating func asked(at now: Duration) -> Int {
        asks.append(now)
        if asks.count > Self.most { asks.removeFirst(asks.count - Self.most) }
        grown = max(grown, asks.filter { now - $0 < Self.burst }.count)
        return size
    }

    /// ``release`` passed since the last open: the bursts' count goes.
    /// - Returns: The pages the pool keeps from now on, or nil when an open came in the meantime (nothing changes).
    public mutating func released(at now: Duration) -> Int? {
        if let last = asks.last, now - last < Self.release { return nil }
        forget()
        return size
    }

    /// The bursts' count goes at once (memory pressure dropped the pages).
    public mutating func forget() {
        asks.removeAll()
        grown = 1
    }
}
