import CoreGraphics
import Foundation

struct TerminalTimestampScrollbarState: Equatable {
    let total: Int
    let offset: Int
    let len: Int

    init(total: Int, offset: Int, len: Int) {
        self.total = max(0, total)
        self.offset = max(0, offset)
        self.len = max(0, len)
    }

    init(_ scrollbar: GhosttyScrollbar) {
        self.init(
            total: Int(clamping: scrollbar.total),
            offset: Int(clamping: scrollbar.offset),
            len: Int(clamping: scrollbar.len)
        )
    }

    static func visibleWindow(
        total: Int,
        fallbackLen: Int,
        visibleTopRow: CGFloat,
        viewportHeight: CGFloat,
        cellHeight: CGFloat
    ) -> Self {
        let total = max(0, total)
        guard total > 0 else {
            return Self(total: 0, offset: 0, len: 0)
        }

        let visibleOffset = min(total, max(0, Int(floor(visibleTopRow))))
        let viewportLen: Int
        if cellHeight > 0, viewportHeight > 0 {
            viewportLen = Int(ceil(viewportHeight / cellHeight)) + 1
        } else {
            viewportLen = fallbackLen
        }
        let len = min(max(0, total - visibleOffset), max(fallbackLen, viewportLen, 0))
        return Self(total: total, offset: visibleOffset, len: len)
    }
}

struct TerminalTimestampVisibleRow: Equatable {
    let row: Int
    let timestamp: Date
}

final class TerminalTimestampStore {
    private let maxRetainedRows: Int
    private var timestampsByRow: [Int: Date] = [:]
    private var oldestTrackedRow: Int?
    private var newestTrackedRow: Int?
    private var lastScrollbar: TerminalTimestampScrollbarState?

    init(maxRetainedRows: Int = 20_000) {
        self.maxRetainedRows = max(1, maxRetainedRows)
    }

    func record(
        scrollbar: TerminalTimestampScrollbarState,
        at date: Date,
        markVisibleRows: Bool
    ) {
        if let previous = lastScrollbar {
            if scrollbar.total < previous.total {
                pruneRows(atOrAbove: scrollbar.total)
            } else if scrollbar.total > previous.total {
                for row in previous.total..<scrollbar.total {
                    recordTimestamp(for: row, at: date)
                }
            }
        }

        if markVisibleRows {
            for row in visibleRange(for: scrollbar) where timestampsByRow[row] == nil {
                recordTimestamp(for: row, at: date)
            }
        }

        prune(forTotalRows: scrollbar.total)
        lastScrollbar = scrollbar
    }

    func visibleRows(for scrollbar: TerminalTimestampScrollbarState) -> [TerminalTimestampVisibleRow] {
        visibleRange(for: scrollbar).compactMap { row in
            guard let timestamp = timestampsByRow[row] else { return nil }
            return TerminalTimestampVisibleRow(row: row, timestamp: timestamp)
        }
    }

    private func visibleRange(for scrollbar: TerminalTimestampScrollbarState) -> Range<Int> {
        guard scrollbar.total > 0, scrollbar.len > 0 else { return 0..<0 }
        let lower = min(scrollbar.offset, scrollbar.total)
        let upper = min(scrollbar.total, lower + scrollbar.len)
        return lower..<upper
    }

    private func recordTimestamp(for row: Int, at date: Date) {
        let isNewRow = timestampsByRow[row] == nil
        timestampsByRow[row] = date

        guard isNewRow else { return }
        oldestTrackedRow = min(oldestTrackedRow ?? row, row)
        newestTrackedRow = max(newestTrackedRow ?? row, row)
    }

    private func pruneRows(atOrAbove upperBound: Int) {
        guard let newestTrackedRow, newestTrackedRow >= upperBound else { return }
        for row in upperBound...newestTrackedRow {
            timestampsByRow.removeValue(forKey: row)
        }
        refreshNewestTrackedRow(startingAt: upperBound - 1)
    }

    private func prune(forTotalRows totalRows: Int) {
        let minimumRow = max(0, totalRows - maxRetainedRows)
        guard let oldestTrackedRow, oldestTrackedRow < minimumRow else { return }

        for row in oldestTrackedRow..<minimumRow {
            timestampsByRow.removeValue(forKey: row)
        }
        refreshOldestTrackedRow(startingAt: minimumRow)
    }

    private func refreshOldestTrackedRow(startingAt row: Int) {
        guard !timestampsByRow.isEmpty else {
            clearTrackedBounds()
            return
        }
        guard let newestTrackedRow else {
            refreshTrackedBounds()
            return
        }

        var candidate = row
        while candidate <= newestTrackedRow {
            if timestampsByRow[candidate] != nil {
                oldestTrackedRow = candidate
                return
            }
            candidate += 1
        }

        refreshTrackedBounds()
    }

    private func refreshNewestTrackedRow(startingAt row: Int) {
        guard !timestampsByRow.isEmpty else {
            clearTrackedBounds()
            return
        }
        guard let oldestTrackedRow else {
            refreshTrackedBounds()
            return
        }

        var candidate = row
        while candidate >= oldestTrackedRow {
            if timestampsByRow[candidate] != nil {
                newestTrackedRow = candidate
                return
            }
            candidate -= 1
        }

        refreshTrackedBounds()
    }

    private func refreshTrackedBounds() {
        guard !timestampsByRow.isEmpty else {
            clearTrackedBounds()
            return
        }

        var oldest = Int.max
        var newest = Int.min
        for row in timestampsByRow.keys {
            oldest = min(oldest, row)
            newest = max(newest, row)
        }
        oldestTrackedRow = oldest
        newestTrackedRow = newest
    }

    private func clearTrackedBounds() {
        oldestTrackedRow = nil
        newestTrackedRow = nil
    }
}
