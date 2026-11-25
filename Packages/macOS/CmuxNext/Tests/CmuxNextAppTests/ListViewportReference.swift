import CmuxNextDesign
import CoreGraphics

/// The list scroll rule as `ListViewport` held it at feat c7d588bf3df1, word for word: the anchor and a row's own move
/// from two sets of every id and two neighbour tables of every row. The tests of SIDEBAR ROW CHANGE compare the rule
/// that reads the rows in view (`ListViewportChange`) with this one, so the scroll after a change is the same as
/// before, case by case. Test code only: nothing in the app reads every row for a scroll.
nonisolated struct ListViewportReference<ID: Hashable & Sendable> {
    typealias Item = ListViewport<ID>.Item

    var items: [Item]
    var viewport: CGFloat
    var content: CGFloat

    static var epsilon: CGFloat { 0.01 }

    /// The parts of the rule that read no row list (not changed by SIDEBAR ROW CHANGE): `clamp`, `reveal`, `isFullyVisible`.
    private var frame: ListViewport<ID> { ListViewport(items: [], viewport: viewport, content: content) }

    func item(_ id: ID) -> Item? { items.first { $0.id == id } }

    func anchor(at offset: CGFloat, next: ListViewportReference<ID>) -> Item? {
        let visible = { (item: Item) in item.end > offset + Self.epsilon && item.start < offset + self.viewport - Self.epsilon }
        let newIDs = Set(next.items.map(\.id))
        guard items.contains(where: { visible($0) && newIDs.contains($0.id) }) else { return nil }
        let oldIDs = Set(items.map(\.id))
        let before = Self.neighbours(items.map(\.id).filter { newIDs.contains($0) })
        let after = Self.neighbours(next.items.map(\.id).filter { oldIDs.contains($0) })
        var firstSurviving: Item?
        for item in items where visible(item) && newIDs.contains(item.id) {
            if firstSurviving == nil { firstSurviving = item }
            guard let old = before[item.id], let new = after[item.id] else { continue }
            if old.previous == new.previous || old.next == new.next { return item }
        }
        return firstSurviving
    }

    private static func neighbours(_ order: [ID]) -> [ID: (previous: ID?, next: ID?)] {
        var result: [ID: (previous: ID?, next: ID?)] = [:]
        result.reserveCapacity(order.count)
        for (index, id) in order.enumerated() {
            result[id] = (index > 0 ? order[index - 1] : nil, index + 1 < order.count ? order[index + 1] : nil)
        }
        return result
    }

    func anchored(from old: ListViewportReference<ID>, offset: CGFloat) -> CGFloat {
        var next = offset
        if let anchor = old.anchor(at: offset, next: self), let moved = item(anchor.id) {
            next += moved.start - anchor.start
        }
        return frame.clamp(next)
    }

    func settle(from old: ListViewportReference<ID>, offset: CGFloat, focused: ID?, newFocus: ID?, padding: CGFloat,
                userMoved: Bool, extent: Item? = nil) -> CGFloat {
        let next = anchored(from: old, offset: offset)
        guard let newFocus, let target = (newFocus != focused ? extent : nil) ?? item(newFocus) else { return next }
        let wasVisible = old.item(newFocus).map { old.frame.isFullyVisible($0, at: offset, padding: 0) } ?? false
        guard newFocus != focused || userMoved || wasVisible || old.movedByItself(newFocus, in: self) else { return next }
        if frame.isFullyVisible(target, at: next, padding: 0) { return next }
        return frame.reveal(target, from: next, padding: padding)
    }

    func movedByItself(_ id: ID, in next: ListViewportReference<ID>) -> Bool {
        let oldIDs = Set(items.map(\.id)), newIDs = Set(next.items.map(\.id))
        guard oldIDs.contains(id), newIDs.contains(id) else { return false }
        guard let before = Self.neighbours(items.map(\.id).filter { newIDs.contains($0) })[id],
              let after = Self.neighbours(next.items.map(\.id).filter { oldIDs.contains($0) })[id] else { return false }
        return before.previous != after.previous && before.next != after.next
    }
}
