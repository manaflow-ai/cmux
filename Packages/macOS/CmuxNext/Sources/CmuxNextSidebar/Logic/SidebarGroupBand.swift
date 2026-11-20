import CmuxNextDesign
import CoreGraphics
import Foundation

/// Drag to group on a loose row (spec 1780d02): the card's centre in the
/// row's onto band (`DropResolver.ontoBand`) groups at once. Once entered,
/// the band's edges are sticky out to `holdZone`, so a drop near an edge
/// never flickers between group and reorder.
nonisolated struct SidebarGroupBand: Sendable {
    /// The loose row under the card's centre that a drop could group
    /// with, and the centre's place in it (0 top, 1 bottom).
    struct Hit: Hashable, Sendable {
        var anchor: WorkspaceID
        var fraction: CGFloat
    }

    /// The onto band; empty when grouping on drop is off.
    static var zone: ClosedRange<CGFloat> { DropResolver.ontoBand.start...max(DropResolver.ontoBand.start, DropResolver.ontoBand.end) }
    /// A sliver wide, so the centre band's reorder zones keep their size (spec 1780d02).
    static var holdZone: ClosedRange<CGFloat> { (zone.lowerBound - 0.05)...(zone.upperBound + 0.05) }

    /// The row the band has grouped with, if any.
    private(set) var armed: WorkspaceID?

    @discardableResult
    mutating func update(_ hit: Hit?) -> WorkspaceID? {
        guard let hit, Self.zone.lowerBound < Self.zone.upperBound else {
            armed = nil
            return nil
        }
        let range = hit.anchor == armed ? Self.holdZone : Self.zone
        armed = range.contains(hit.fraction) ? hit.anchor : nil
        return armed
    }

    /// The loose row of the same machine at display `y` that `dragged`
    /// could group with. Grouped rows, group headers, pinned rows and
    /// other machines keep the leading-edge rule.
    static func hit(y: CGFloat, layout: SidebarLayout, hidden: Set<SidebarRowKey>, dragged: [WorkspaceID],
                    sections: [SidebarSection]) -> Hit? {
        guard let row = shownRow(at: y, in: layout, hidden: hidden), row.height > 0,
              case let .machine(machine) = row.section, case let .workspace(anchor) = row.key, row.group == nil,
              dragged.allSatisfy({ SidebarEdits.workspace($0, in: sections)?.machineID == machine }) else { return nil }
        return Hit(anchor: anchor, fraction: (y - row.y) / row.height)
    }

    /// The first row in `layout` that holds `y` and is not `hidden`, found from the rows starting at or above `y`
    /// (the rows are in y order and do not overlap), so a move costs the same at any number of rows. A card over its
    /// own hidden slot finds none, which a scan from the top paid for with every row.
    static func shownRow(at y: CGFloat, in layout: SidebarLayout, hidden: Set<SidebarRowKey>) -> SidebarRow? {
        guard var i = layout.lastIndex(startingAtOrBefore: y) else { return nil }
        var found: SidebarRow?
        while i >= 0, layout.rows[i].maxY > y || layout.rows[i].height == 0 {
            let row = layout.rows[i]
            if y < row.maxY, !hidden.contains(row.key) { found = row }
            i -= 1
        }
        return found
    }
}
