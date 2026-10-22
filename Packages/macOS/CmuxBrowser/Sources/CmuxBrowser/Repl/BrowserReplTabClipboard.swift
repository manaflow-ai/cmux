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
///
/// What it holds is the owner's memory: each write is charged to the
/// owner's ledger (``BrowserReplResource/clipboardBytes``) at the size
/// `measure` gives its items, replacing the earlier write's charge, and a
/// write past the ledger's limit is refused, keeping the earlier items. The
/// charge goes back when the owner leaves or the clipboard is dropped.
public struct BrowserReplTabClipboard<Item> {
    /// One owner's time holding the tab: its session and a number no other
    /// tenure of this tab has.
    public struct Tenure: Sendable, Equatable {
        public let owner: String
        let generation: UInt64
    }

    /// The bytes the items hold, in the owner's ledger; released when the
    /// clipboard lets them go (a new owner, or the tab's attachment gone).
    private final class Charge {
        let ledger: BrowserReplResourceLedger
        var bytes = 0

        init(ledger: BrowserReplResourceLedger) {
            self.ledger = ledger
        }

        deinit {
            ledger.release(bytes, of: .clipboardBytes)
        }
    }

    /// The current owner's tenure; `nil` for a user's tab.
    public private(set) var tenure: Tenure?
    private var items: [Item] = []
    private var lastGeneration: UInt64 = 0
    private var charge: Charge?
    private let measure: (Item) -> Int

    /// - Parameter measure: the bytes one item holds, as the owner's ledger
    ///   counts them.
    public init(measure: @escaping (Item) -> Int = { _ in 0 }) {
        self.measure = measure
    }

    /// Sets the tab's live creator (`nil`: the tab is the user's). Another
    /// owner than the current one empties the clipboard and starts a new
    /// tenure, whose writes `ledger` (the owner's) is charged for; the same
    /// owner keeps both.
    public mutating func setOwner(_ owner: String?, ledger: BrowserReplResourceLedger? = nil) {
        guard owner != tenure?.owner else { return }
        items = []
        charge = nil
        guard let owner else {
            tenure = nil
            return
        }
        lastGeneration += 1
        tenure = Tenure(owner: owner, generation: lastGeneration)
        charge = ledger.map(Charge.init(ledger:))
    }

    /// What `sessionID` reads (`clipboard.read`): `nil` unless it owns the tab.
    public func read(by sessionID: String) -> [Item]? {
        tenure?.owner == sessionID ? items : nil
    }

    /// `sessionID`'s write (`clipboard.write`).
    /// - Returns: `false`, storing nothing, unless it owns the tab.
    /// - Throws: the ledger's refusal, storing nothing.
    @discardableResult
    public mutating func write(_ newItems: [Item], by sessionID: String) throws(BrowserReplResourceLimitError) -> Bool {
        guard tenure?.owner == sessionID else { return false }
        if let refusal = replace(with: newItems) { throw refusal }
        return true
    }

    /// A page script's write (`page-clipboard.js`).
    /// - Returns: `false`, storing nothing, unless a session owns the tab.
    /// - Throws: the ledger's refusal, storing nothing.
    @discardableResult
    public mutating func writeFromPage(_ newItems: [Item]) throws(BrowserReplResourceLimitError) -> Bool {
        guard tenure != nil else { return false }
        if let refusal = replace(with: newItems) { throw refusal }
        return true
    }

    /// Stores what a Copy or Cut that began in `tenure` took.
    /// - Returns: `false`, storing nothing, once that tenure has ended.
    /// - Throws: the ledger's refusal, storing nothing.
    @discardableResult
    public mutating func store(_ newItems: [Item], during tenure: Tenure) throws(BrowserReplResourceLimitError) -> Bool {
        guard self.tenure == tenure else { return false }
        if let refusal = replace(with: newItems) { throw refusal }
        return true
    }

    /// What a Paste that began in `tenure` puts in the page; empty once
    /// that tenure has ended.
    public func items(during tenure: Tenure) -> [Item] {
        self.tenure == tenure ? items : []
    }

    /// Stores `newItems` in place of the items, charged in their place, or
    /// returns the ledger's refusal, storing nothing.
    private mutating func replace(with newItems: [Item]) -> BrowserReplResourceLimitError? {
        if let charge {
            let bytes = newItems.reduce(0) { $0 + measure($1) }
            if let refusal = charge.ledger.resize(.clipboardBytes, from: charge.bytes, to: bytes) { return refusal }
            charge.bytes = bytes
        }
        items = newItems
        return nil
    }
}

extension BrowserReplTabClipboard where Item == [String: Any] {
    /// `sessionID`'s `clipboard.write` with its parameters as the driver
    /// got them, `{ items: [{ type, base64 }] }`: checked by the page
    /// clipboard's validator (``BrowserReplPageClipboard/items(from:)``,
    /// at most 32 items and 64 MiB of Base64) before it is stored.
    /// - Returns: `false`, storing nothing, unless it owns the tab.
    /// - Throws: `invalid` for items past the validator or the ledger,
    ///   storing nothing.
    @discardableResult
    public mutating func write(message: Any, by sessionID: String) throws(BrowserReplDriverError) -> Bool {
        guard let newItems = BrowserReplPageClipboard.items(from: message) else {
            throw BrowserReplDriverError(
                code: "invalid",
                message: "clipboard.write: items: expected at most \(BrowserReplPageClipboard.maximumItems) items of a MIME type and Base64 data, \(BrowserReplPageClipboard.maximumBase64Characters >> 20) MiB of Base64 in all"
            )
        }
        guard tenure?.owner == sessionID else { return false }
        if let refusal = replace(with: newItems) { throw refusal.driverError("clipboard.write") }
        return true
    }
}
