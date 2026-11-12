public import Foundation

/// One history read: its entries, newest first, and whether an owner did not answer after its
/// retries, so an empty list is not taken for "nothing there".
public nonisolated struct HistoryRead: Sendable {
    public var entries: [HistoryEntry]
    public var unavailable: Bool
    /// The kinds whose entries are not complete yet (``DaemonHistoryList/pendingKinds``): the list is
    /// short for now, and the reader shows that and reads again.
    public var pending: Set<HistoryEntry.Kind>

    public init(entries: [HistoryEntry], unavailable: Bool = false, pending: Set<HistoryEntry.Kind> = []) {
        self.entries = entries
        self.unavailable = unavailable
        self.pending = pending
    }

    /// What a list says under its rows, so an empty query never reads "No Results" and a failed read is never hidden.
    public struct Status: Hashable, Sendable {
        public let id: String
        public let title: String
        public let detail: String?
        public let symbol: String
        /// The read did not answer: choosing the row reads again.
        public let canRetry: Bool
    }

    /// Unanswered (with or without the rows other owners gave): Try Again. An unfiltered Recently Closed
    /// with no rows: nothing was closed. Else nil (the rows, or the list's own "No Results" for a search).
    public func status(_ query: HistoryQuery) -> Status? {
        if unavailable {
            return Status(id: "history.status.unavailable", title: HistoryStrings.readFailed, detail: HistoryStrings.readFailedHint,
                          symbol: "exclamationmark.triangle", canRetry: true)
        }
        guard entries.isEmpty, query.kinds == [.closed], query.text.isEmpty, query.range == .all else { return nil }
        return Status(id: "history.status.empty", title: HistoryStrings.menuNothingClosed, detail: nil, symbol: "clock.arrow.circlepath",
                      canRetry: false)
    }

    public static var tryAgain: String { HistoryStrings.tryAgain }
}

extension TitlebarHistoryClosedSection {
    /// The Recently Closed section of `entries` (the closed ones, newest first), or `.unavailable`
    /// when no connected machine serves closed history.
    public init(_ entries: [HistoryEntry], served: Bool) {
        guard served else {
            self = .unavailable
            return
        }
        let rows = entries.compactMap { entry -> TitlebarHistoryClosedRow? in
            guard case .closed(let item) = entry.payload else { return nil }
            let detail = [entry.detail, entry.machineName].compactMap { $0 }.joined(separator: " · ")
            return TitlebarHistoryClosedRow(id: item.id, kind: item.kind, title: entry.title, detail: detail.isEmpty ? nil : detail)
        }
        self = rows.isEmpty ? .empty : .rows(rows)
    }
}

extension LocationTrail {
    /// Renames the places `sections` list to their tabs' current titles (`liveTitle`, nil for a
    /// tab that is gone) in place. Only the listed places are read, so the cost follows the list.
    /// Returns true when an entry changed.
    public mutating func retitle(_ sections: [LocationTrailMenuSection], liveTitle: (HistoryLocation) -> String?) -> Bool {
        var seen: Set<HistoryLocation.Key> = []
        var renamed = false
        for item in sections.lazy.flatMap(\.items) where seen.insert(item.entry.location.key).inserted {
            if let title = liveTitle(item.entry.location), retitle(item.entry.location.key, title: title) { renamed = true }
        }
        return renamed
    }
}
