/// Each row key's position in a ``SidebarLayout``, kept current through splices without rehashing every row.
///
/// A group's fold replaces the group's member rows and leaves the rest of the list where it is, only
/// further down or up. Rebuilding a key-to-position table after it would hash every row of the list,
/// so the fold's cost would grow with the workspaces (plans/cmux-next/state-ownership-DESIGN.md:
/// 10,000 workspaces must fold as fast as 100). Instead the table keeps the positions it was built
/// with, plus the splices since then, and a lookup moves a position past each splice. After
/// `compactAfter` splices it is built again, once (amortized over those folds).
nonisolated struct SidebarLayoutKeyIndex: Sendable {
    /// One replacement of `removed` rows at `start` by `inserted` rows.
    private struct Splice: Sendable {
        var start: Int
        var removed: Int
        var inserted: Int
    }

    /// Positions as built (valid before every splice).
    private var base: [SidebarRowKey: Int]
    /// Keys a splice inserted: their position right after splice `epoch - 1`.
    private var added: [SidebarRowKey: (position: Int, epoch: Int)] = [:]
    private var splices: [Splice] = []
    /// Splices kept before the table is built again.
    static let compactAfter = 32

    init(rows: [SidebarRow]) {
        var base: [SidebarRowKey: Int] = [:]
        base.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() { base[row.key] = i }
        self.base = base
    }

    /// The position of `key`'s row, or nil when no row has it.
    func position(of key: SidebarRowKey) -> Int? {
        if let entry = added[key] { return moved(entry.position, from: entry.epoch) }
        return base[key].flatMap { moved($0, from: 0) }
    }

    /// `position` (valid after `epoch` splices) moved past the splices after it; nil when one removed it.
    private func moved(_ position: Int, from epoch: Int) -> Int? {
        var p = position
        for splice in splices[epoch...] {
            if p >= splice.start + splice.removed {
                p += splice.inserted - splice.removed
            } else if p >= splice.start {
                return nil
            }
        }
        return p
    }

    /// `rows` (already spliced) replaced `removed` rows at `start` with `inserted` (their keys, in order).
    mutating func splice(start: Int, removed: Int, inserted: [SidebarRowKey], rows: [SidebarRow]) {
        guard splices.count < Self.compactAfter else { return self = Self(rows: rows) }
        splices.append(Splice(start: start, removed: removed, inserted: inserted.count))
        for (offset, key) in inserted.enumerated() { added[key] = (start + offset, splices.count) }
    }
}
