/// The virtual clipboard of one browser tab that REPL sessions drive:
/// `page.clipboard`, Meta+C, Meta+X and Meta+V, and, in a tab a session
/// created, the page's own Clipboard API and `execCommand("copy" | "cut")`.
///
/// It belongs to the session that created the tab, while that session is
/// attached (its tenure). Only that session reads or writes it. A user's
/// tab (one no live session created, also a kept one) has none: two
/// sessions that drive it never pass bytes to each other through it. When
/// the owner changes the clipboard empties and a new tenure starts, and
/// nothing begun in an earlier tenure (a Copy WebKit was still running, a
/// page write) lands in a later one.
public struct BrowserReplTabClipboard<Item> {
    /// One owner's time holding the tab: its session and a number no other
    /// tenure of this tab has.
    public struct Tenure: Sendable, Equatable {
        public let owner: String
        let generation: UInt64
    }

    /// The current owner's tenure; `nil` for a user's tab.
    public private(set) var tenure: Tenure?
    private var items: [Item] = []
    private var lastGeneration: UInt64 = 0

    public init() {}

    /// Sets the tab's live creator (`nil`: the tab is the user's). Another
    /// owner than the current one empties the clipboard and starts a new
    /// tenure; the same owner keeps both.
    public mutating func setOwner(_ owner: String?) {
        guard owner != tenure?.owner else { return }
        items = []
        guard let owner else {
            tenure = nil
            return
        }
        lastGeneration += 1
        tenure = Tenure(owner: owner, generation: lastGeneration)
    }

    /// What `sessionID` reads (`clipboard.read`): `nil` unless it owns the tab.
    public func read(by sessionID: String) -> [Item]? {
        tenure?.owner == sessionID ? items : nil
    }

    /// `sessionID`'s write (`clipboard.write`).
    /// - Returns: `false`, storing nothing, unless it owns the tab.
    @discardableResult
    public mutating func write(_ newItems: [Item], by sessionID: String) -> Bool {
        guard tenure?.owner == sessionID else { return false }
        items = newItems
        return true
    }

    /// A page script's write (`page-clipboard.js`).
    /// - Returns: `false`, storing nothing, unless a session owns the tab.
    @discardableResult
    public mutating func writeFromPage(_ newItems: [Item]) -> Bool {
        guard tenure != nil else { return false }
        items = newItems
        return true
    }

    /// Stores what a Copy or Cut that began in `tenure` took.
    /// - Returns: `false`, storing nothing, once that tenure has ended.
    @discardableResult
    public mutating func store(_ newItems: [Item], during tenure: Tenure) -> Bool {
        guard self.tenure == tenure else { return false }
        items = newItems
        return true
    }

    /// What a Paste that began in `tenure` puts in the page; empty once
    /// that tenure has ended.
    public func items(during tenure: Tenure) -> [Item] {
        self.tenure == tenure ? items : []
    }
}
