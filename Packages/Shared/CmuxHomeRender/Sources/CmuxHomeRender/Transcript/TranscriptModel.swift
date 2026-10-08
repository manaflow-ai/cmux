import CoreGraphics
import Foundation

/// The rows of the loaded window with prefix sums of their heights. A removed
/// row stays as a ghost (zero height) while it fades out.
@MainActor
final class TranscriptModel {
    struct Row {
        var spec: RowSpec
        var removedAt: Double?
        var insertedAt: Double
        var ghost: Bool { removedAt != nil }
    }

    private(set) var rows: [Row] = []
    /// offsets[i] = top of row i's slot relative to the first slot; offsets[n] = total.
    private(set) var offsets: [CGFloat] = [0]
    private(set) var index: [String: Int] = [:]

    var count: Int { rows.count }
    var total: CGFloat { offsets.last ?? 0 }
    var hasGhosts: Bool { rows.contains(where: \.ghost) }

    /// Replaces the rows. With `ghosts`, rows that disappear stay as ghosts
    /// at their old place (time `t`); without, they go at once.
    func set(_ specs: [RowSpec], at t: Double, ghosts: Bool) {
        let newKeys = Set(specs.map(\.key))
        let old = rows.filter { !$0.ghost }
        var oldIndex: [String: Int] = [:]
        oldIndex.reserveCapacity(old.count)
        for (i, r) in old.enumerated() { oldIndex[r.spec.key] = i }
        var result: [Row] = []
        result.reserveCapacity(specs.count + 4)
        var oi = 0
        for spec in specs {
            while oi < old.count, !newKeys.contains(old[oi].spec.key) {
                if ghosts { var g = old[oi]; g.removedAt = t; result.append(g) }
                oi += 1
            }
            if oi < old.count, old[oi].spec.key == spec.key { oi += 1 }
            if let j = oldIndex[spec.key] {
                var r = old[j]
                r.spec = spec
                result.append(r)
            } else {
                result.append(Row(spec: spec, removedAt: nil, insertedAt: t))
            }
        }
        while oi < old.count {
            if ghosts, !newKeys.contains(old[oi].spec.key) { var g = old[oi]; g.removedAt = t; result.append(g) }
            oi += 1
        }
        // Ghosts that are still fading keep fading (at the end when their place is gone).
        let present = Set(result.map(\.spec.key))
        let fading = rows.filter { $0.ghost && !present.contains($0.spec.key) }
        rows = result + fading
        rebuild()
    }

    /// Removes ghosts that finished fading. Returns true if any were removed.
    @discardableResult
    func dropGhosts(before t: Double) -> Bool {
        let n = rows.count
        rows.removeAll { ($0.removedAt ?? .infinity) <= t }
        guard rows.count != n else { return false }
        rebuild()
        return true
    }

    private func rebuild() {
        offsets = [CGFloat](repeating: 0, count: rows.count + 1)
        index = [:]
        index.reserveCapacity(rows.count)
        var y: CGFloat = 0
        for (i, r) in rows.enumerated() {
            offsets[i] = y
            if !r.ghost { y += r.spec.total }
            index[r.spec.key] = i
        }
        offsets[rows.count] = y
    }

    /// Content top of row i relative to the first slot (bottom aligned in its
    /// slot; a ghost keeps its content below its zero-height slot).
    func contentTop(_ i: Int) -> CGFloat {
        let r = rows[i]
        return r.ghost ? offsets[i] + r.spec.gap : offsets[i + 1] - r.spec.height
    }

    /// Rows whose content may intersect [lo, hi] (relative to the first slot).
    func range(_ lo: CGFloat, _ hi: CGFloat) -> Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        let a = lowerBound(lo - 400), b = min(rows.count, lowerBound(hi + 40) + 1)
        return a..<max(a, b)
    }

    /// First index whose slot bottom is >= y.
    private func lowerBound(_ y: CGFloat) -> Int {
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if offsets[mid + 1] < y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Positions before a change, for the deltas the change animates.
    struct Snapshot {
        var index: [String: Int]
        var offsets: [CGFloat]
        var rows: [Row]

        func contentTop(_ key: String) -> CGFloat? {
            guard let i = index[key] else { return nil }
            let r = rows[i]
            return r.ghost ? offsets[i] + r.spec.gap : offsets[i + 1] - r.spec.height
        }
    }

    var snapshot: Snapshot { Snapshot(index: index, offsets: offsets, rows: rows) }
}
