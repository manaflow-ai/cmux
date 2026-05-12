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
                timestampsByRow = timestampsByRow.filter { entry in entry.key < scrollbar.total }
            } else if scrollbar.total > previous.total {
                for row in previous.total..<scrollbar.total {
                    timestampsByRow[row] = date
                }
            }
        }

        if markVisibleRows {
            for row in visibleRange(for: scrollbar) where timestampsByRow[row] == nil {
                timestampsByRow[row] = date
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

    private func prune(forTotalRows totalRows: Int) {
        let minimumRow = max(0, totalRows - maxRetainedRows)
        timestampsByRow = timestampsByRow.filter { entry in
            entry.key >= minimumRow && entry.key < totalRows
        }
    }
}
