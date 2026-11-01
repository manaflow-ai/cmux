import Foundation

// Where a document drop may go and whether it moves anything (Lawrence 2026-10-30: "i tried to drag home around and
// now it's stuck in this state"). Home dropped back into its own section took a new order key: a change with an undo
// step that draws nothing new. The list's settle ends on a refusal, a no-op reply or a change it shows, so none came,
// and the card waited over Home's slot with Home hidden under it. Home no longer moves; a drop that keeps the items
// where they are sends nothing, and nothing lands above an item that cannot move.
extension SidebarListViewComponents {
    /// `table` (a drag's acceptance) with no gap before an item that cannot move (`LayoutItem.isMovable`): Home stays
    /// first in its section, so nothing lands above it.
    func keepingFixed(_ table: [String: SidebarDocAcceptance]) -> [String: SidebarDocAcceptance] {
        guard let blocks else { return table }
        var table = table
        for item in blocks.sections.values.flatMap(\.items) where !item.isMovable && !item.id.isTransient {
            guard var accepted = table[item.id.rawValue], accepted.before else { continue }
            accepted.before = false
            if !accepted.into && !accepted.after { accepted.refusal = "fixed" }
            table[item.id.rawValue] = accepted
        }
        return table
    }

    /// Whether dropping `items` on `target` leaves them where they are now: they sit together, in order, among the
    /// target's siblings as the list shows them (a block's items, a section's top-level rows, a group's members), and
    /// the target puts them back at that same place. False when the list cannot tell (the move is sent).
    func dropKeepsPlace(_ items: [String], _ target: SidebarDocTarget) -> Bool {
        guard let first = items.first, let siblings = shownSiblings(of: target),
              let start = siblings.firstIndex(of: first), siblings.count - start >= items.count,
              Array(siblings[start..<(start + items.count)]) == items else { return false }
        let staying = siblings.filter { !items.contains($0) }
        let at: Int
        if let before = target.before {
            guard let index = staying.firstIndex(of: before) else { return false }
            at = index
        } else if let after = target.after {
            guard let index = staying.firstIndex(of: after) else { return false }
            at = index + 1
        } else if let index = target.index {
            at = min(max(0, index), staying.count)
        } else {
            at = staying.count // into the section or group: at its end
        }
        return at == start
    }

    /// The item ids the list shows under `target`'s section and parent, in order; nil when it does not draw them.
    private func shownSiblings(of target: SidebarDocTarget) -> [String]? {
        guard let doc = model.docDrag else { return nil }
        if target.parent == nil, let block = blocks?.sections[target.section] {
            // A block draws its section's items (its groups list as rows after them, in no order shared with them).
            return block.items.filter { !$0.id.isTransient }.map(\.id.rawValue)
        }
        guard let section = model.sections.first(where: { doc.section($0.id) == target.section }) else { return nil }
        if let parent = target.parent {
            guard let group = model.group(GroupID(parent)) else { return nil }
            return group.members.compactMap { member in
                switch member {
                case let .workspace(workspace): doc.item(.workspace(workspace.id))
                case let .item(listed): listed.id
                }
            }
        }
        return section.nodes.compactMap { node in
            switch node {
            case let .workspace(workspace): doc.item(.workspace(workspace.id))
            case let .group(group): group.id.rawValue
            case let .item(listed): listed.id
            }
        }
    }

    /// The base y whose hit puts a block drag's items back at their own place in `source`'s section, or nil when no
    /// probe at the edges of their vacated slot does (a section that refuses them, a slot gone from the base).
    func originHit(_ geometry: SidebarDragGeometry, source: (section: String, item: LayoutItemID), items: [String], x: CGFloat) -> CGFloat? {
        guard let all = blocks?.sections[source.section]?.items.map(\.id.rawValue), let first = items.first,
              let start = all.firstIndex(of: first), let row = displayed.row(for: .block(source.section)),
              let frame = drag?.restFrame else { return nil }
        // The slot's top edge is where the next item starts in the base; just above it is the previous item's lower half.
        for y in [frame.minY - 0.5, frame.minY + 0.5] where y >= row.y {
            guard let hit = geometry.hit(CGPoint(x: x, y: y)), let target = hit.target, hit.slot.section == source.section,
                  blockIndex(target, section: source.section, moving: items) == start else { continue }
            return y
        }
        return nil
    }
}
