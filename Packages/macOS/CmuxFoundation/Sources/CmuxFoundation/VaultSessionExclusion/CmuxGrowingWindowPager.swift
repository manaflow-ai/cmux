import Foundation

/// Pages a newest-first source through a filter. Rows the filter hides never
/// consume the requested window, and the work grows with the request: each
/// page starts at twice `offset + limit` and reads more only while too few
/// rows pass the filter, bounded by `cap`.
public struct CmuxGrowingWindowPager: Sendable {
    /// The most rows one page may inspect, unless the page itself is larger.
    public let cap: Int

    public init(cap: Int) {
        self.cap = cap
    }

    /// Pages a candidate snapshot that is discovered once. The first window is
    /// twice the page; with `grows`, each later window doubles the inspected
    /// prefix and parses only candidates not yet inspected, until
    /// `offset + limit` rows pass `isIncluded` or the snapshot (bounded by
    /// `cap`) is spent. `parse` may drop candidates, so a short window is not
    /// the end of the snapshot.
    public func snapshotPage<Element>(
        candidateCount: Int,
        offset: Int,
        limit: Int,
        grows: Bool,
        parse: (Range<Int>) async -> [Element],
        isIncluded: (Element) -> Bool
    ) async -> [Element] {
        let target = offset + limit
        let maxWork = min(candidateCount, cap)
        var inspected = 0
        var windowEnd = doubled(target, upTo: maxWork)
        var matched: [Element] = []
        while inspected < windowEnd {
            matched.append(contentsOf: await parse(inspected..<windowEnd).filter(isIncluded))
            inspected = windowEnd
            if Task.isCancelled { return [] }
            if !grows || matched.count >= target { break }
            windowEnd = doubled(windowEnd, upTo: maxWork)
        }
        return Array(matched.prefix(target).dropFirst(offset).prefix(limit))
    }

    /// Pages a source that can only read its newest `n` rows. Each read
    /// reruns the source's loader, so a page takes at most two: with
    /// `startsSmall`, twice the page first, and `cap` only when too few of
    /// those rows pass `isIncluded`; without it, `cap` once. A short first
    /// read does not end the page, because some readers return less for one
    /// request size (Antigravity reads one history page for its preview size).
    public func prefixPage<Element>(
        offset: Int,
        limit: Int,
        startsSmall: Bool,
        read: (Int) async -> [Element],
        isIncluded: (Element) -> Bool
    ) async -> [Element] {
        let target = offset + limit
        guard limit > 0 else { return [] }
        let maxRead = max(cap, target)
        var readLimit = startsSmall ? doubled(target, upTo: maxRead) : maxRead
        while true {
            let included = await read(readLimit).filter(isIncluded)
            if Task.isCancelled { return [] }
            if included.count >= target || readLimit >= maxRead {
                return Array(included.prefix(target).dropFirst(offset).prefix(limit))
            }
            readLimit = maxRead
        }
    }

    /// `min(2 * value, bound)`, written so the doubling cannot overflow.
    private func doubled(_ value: Int, upTo bound: Int) -> Int {
        value > bound / 2 ? bound : value * 2
    }
}
