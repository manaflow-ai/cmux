import CoreGraphics
import Foundation

/// The transcript's rows and their tops (prefix sums), updated incrementally
/// from a ``WindowChange`` (MessagesLab `Layout.update`): only the messages a
/// change touched, their neighbours and the receipt holders are derived again.
/// Visible rows come from a binary search over `tops`.
struct TranscriptLayout {
    private(set) var rows: [TranscriptRow] = []
    /// Top of each row from the content top (points, gap included before it).
    private(set) var tops: [CGFloat] = []
    /// First row index of each window message (`rows.count` past the last).
    private(set) var messageStarts: [Int] = []
    private(set) var totalHeight: CGFloat = 0
    private(set) var holders = ReceiptHolders()
    private(set) var hasTyping = false
    private var keyIndex: [String: Int]?

    var isEmpty: Bool { rows.isEmpty }

    /// Derives every row again.
    mutating func rebuild(_ window: TranscriptWindow, context: RowContext) {
        holders = ReceiptHolders.find(in: window, meID: context.meID, readThrough: context.readThrough)
        rows.removeAll(keepingCapacity: true)
        messageStarts.removeAll(keepingCapacity: true)
        for index in 0..<window.count {
            messageStarts.append(rows.count)
            rows += RowDerivation.rows(at: index, in: window, holders: holders, context: context)
        }
        hasTyping = false
        appendTyping(window, context: context)
        recomputeTops(from: 0, topPadding: context.geometry.topPadding)
    }

    /// Applies one window mutation. Returns the first row index whose top may have changed.
    @discardableResult
    mutating func apply(_ change: WindowChange, window: TranscriptWindow, context: RowContext) -> Int {
        let pad = context.geometry.topPadding
        switch change {
        case .none:
            return rows.count
        case .full:
            rebuild(window, context: context)
            return 0
        case .prepend(let count):
            removeTyping()
            let derive = min(count + 1, window.count)
            let newHolders = ReceiptHolders.find(in: window, meID: context.meID, readThrough: context.readThrough)
            // the old first message (now `count`) gets its neighbour: its rows are replaced too
            let oldEnd = messageStarts.count > 0 ? (messageStarts.count > 1 ? messageStarts[1] : rows.count) : 0
            var fresh: [TranscriptRow] = []
            var starts: [Int] = []
            for index in 0..<derive {
                starts.append(fresh.count)
                fresh += RowDerivation.rows(at: index, in: window, holders: newHolders, context: context)
            }
            let shift = fresh.count - oldEnd
            rows.replaceSubrange(0..<oldEnd, with: fresh)
            let rest = messageStarts.dropFirst(1).map { $0 + shift }
            messageStarts = starts + rest
            holders = newHolders
            appendTyping(window, context: context)
            recomputeTops(from: 0, topPadding: pad)
            return 0
        case .evictTop(let count):
            removeTyping()
            let cut = count < messageStarts.count ? messageStarts[count] : rows.count
            rows.removeSubrange(0..<cut)
            messageStarts = messageStarts.dropFirst(count).map { $0 - cut }
            holders = ReceiptHolders.find(in: window, meID: context.meID, readThrough: context.readThrough)
            if window.count > 0 { replaceMessages(0...0, window: window, context: context) }
            appendTyping(window, context: context)
            recomputeTops(from: 0, topPadding: pad)
            return 0
        case .evictBottom(let count):
            removeTyping()
            let keep = messageStarts.count - count
            let cut = keep < messageStarts.count ? messageStarts[keep] : rows.count
            rows.removeSubrange(cut...)
            messageStarts.removeSubrange(keep...)
            let first = retouch([max(0, keep - 1)], window: window, context: context)
            appendTyping(window, context: context)
            recomputeTops(from: first, topPadding: pad)
            return first
        case .touched(let indexes):
            removeTyping()
            // messages appended at the end have no rows yet
            while messageStarts.count < window.count { messageStarts.append(rows.count) }
            if messageStarts.count > window.count {
                let cut = messageStarts[window.count]
                rows.removeSubrange(cut...)
                messageStarts.removeSubrange(window.count...)
            }
            let first = retouch(Array(indexes), window: window, context: context)
            appendTyping(window, context: context)
            recomputeTops(from: first, topPadding: pad)
            return first
        }
    }

    /// The typing row appears or leaves (it is always last).
    mutating func setTyping(_ window: TranscriptWindow, context: RowContext) -> Int {
        let had = hasTyping
        removeTyping()
        let from = rows.count
        appendTyping(window, context: context)
        if had != hasTyping || hasTyping { recomputeTops(from: max(0, from - 1), topPadding: context.geometry.topPadding) }
        return from
    }

    /// The read cursor or the identity of the receipt holders changed.
    mutating func refreshReceipts(_ window: TranscriptWindow, context: RowContext) -> Int {
        removeTyping()
        let first = retouch([], window: window, context: context)
        appendTyping(window, context: context)
        recomputeTops(from: first, topPadding: context.geometry.topPadding)
        return first
    }

    /// Replaces estimated sizes in `range` with measurements. Returns true when a height changed.
    mutating func measure(rows range: Range<Int>, measurer: Measurer, geometry g: TranscriptGeometry) -> Bool {
        var first: Int?
        for index in range where rows[index].estimated {
            guard let key = rows[index].measureKey, let part = rows[index].part else { continue }
            let size = measurer.size(of: part, key: key, geometry: g)
            rows[index].height = size.height
            rows[index].width = size.width
            rows[index].x = g.bubbleX(width: size.width, outgoing: rows[index].isOutgoing)
            rows[index].estimated = false
            first = first ?? index
        }
        guard let first else { return false }
        recomputeTops(from: first, topPadding: g.topPadding)
        return true
    }

    // MARK: Queries

    /// First row index for which `predicate` holds (monotonic over rows).
    func lowerBound(_ predicate: (Int) -> Bool) -> Int {
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if predicate(mid) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// First row whose bottom is at or below `y` (content coordinates).
    func firstRow(endingAtOrBelow y: CGFloat) -> Int {
        lowerBound { tops[$0] + rows[$0].height >= y }
    }

    /// First row whose top is below `y`.
    func firstRow(startingBelow y: CGFloat) -> Int {
        lowerBound { tops[$0] > y }
    }

    mutating func rowIndex(of key: String) -> Int? {
        if keyIndex == nil {
            var index: [String: Int] = [:]
            index.reserveCapacity(rows.count)
            for (i, row) in rows.enumerated() where index[row.key] == nil { index[row.key] = i }
            keyIndex = index
        }
        return keyIndex?[key]
    }

    /// Window message index that owns row `row`.
    func messageIndex(ofRow row: Int) -> Int? {
        guard !messageStarts.isEmpty else { return nil }
        var lo = 0, hi = messageStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if messageStarts[mid] <= row { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: Private

    /// Derives the touched messages, their neighbours and the old and new
    /// receipt holders again; returns the first row index that changed.
    private mutating func retouch(_ touched: [Int], window: TranscriptWindow, context: RowContext) -> Int {
        let newHolders = ReceiptHolders.find(in: window, meID: context.meID, readThrough: context.readThrough)
        var affected = Set<Int>()
        for index in touched {
            for neighbour in (index - 1)...(index + 1) where neighbour >= 0 && neighbour < window.count {
                affected.insert(neighbour)
            }
        }
        if newHolders != holders {
            for key in holders.keys + newHolders.keys {
                if let index = window.index(ofRowKey: key) { affected.insert(index) }
            }
        }
        holders = newHolders
        guard let lo = affected.min(), let hi = affected.max() else { return rows.count }
        return replaceMessages(lo...hi, window: window, context: context)
    }

    @discardableResult
    private mutating func replaceMessages(_ range: ClosedRange<Int>, window: TranscriptWindow, context: RowContext) -> Int {
        let start = messageStarts[range.lowerBound]
        let end = range.upperBound + 1 < messageStarts.count ? messageStarts[range.upperBound + 1] : rows.count
        var fresh: [TranscriptRow] = []
        var starts: [Int] = []
        for index in range {
            starts.append(start + fresh.count)
            fresh += RowDerivation.rows(at: index, in: window, holders: holders, context: context)
        }
        let shift = fresh.count - (end - start)
        rows.replaceSubrange(start..<end, with: fresh)
        messageStarts.replaceSubrange(range, with: starts)
        if shift != 0 {
            for index in (range.upperBound + 1)..<messageStarts.count { messageStarts[index] += shift }
        }
        return start
    }

    private mutating func appendTyping(_ window: TranscriptWindow, context: RowContext) {
        guard context.typing, window.atNewest, !hasTyping else { return }
        rows.append(RowDerivation.typingRow(after: window.count > 0 ? window[window.count - 1] : nil, context: context))
        hasTyping = true
    }

    private mutating func removeTyping() {
        guard hasTyping else { return }
        rows.removeLast()
        hasTyping = false
    }

    private mutating func recomputeTops(from: Int, topPadding: CGFloat) {
        keyIndex = nil
        let start = min(from, tops.count, rows.count)
        var y = start == 0 ? topPadding : tops[start - 1] + rows[start - 1].height
        tops.removeSubrange(start...)
        tops.reserveCapacity(rows.count)
        rows.withUnsafeBufferPointer { buffer in
            for index in start..<buffer.count {
                y += buffer[index].gapBefore
                tops.append(y)
                y += buffer[index].height
            }
        }
        totalHeight = y
    }
}
