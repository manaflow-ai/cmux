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
    static func hit(y: CGFloat, rows: [SidebarRow], hidden: Set<SidebarRowKey>, dragged: [WorkspaceID],
                    sections: [SidebarSection]) -> Hit? {
        guard let row = rows.first(where: { y >= $0.y && y < $0.maxY && !hidden.contains($0.key) }), row.height > 0,
              case let .machine(machine) = row.section, case let .workspace(anchor) = row.key, row.group == nil,
              dragged.allSatisfy({ SidebarEdits.workspace($0, in: sections)?.machineID == machine }) else { return nil }
        return Hit(anchor: anchor, fraction: (y - row.y) / row.height)
    }

    /// The first color no group in `sections` uses yet, so a new group
    /// stands apart; never blue or grey.
    static func newGroupColor(in sections: [SidebarSection]) -> GroupColor {
        // The app's own pick follows the no-blue rule (GroupColor.automatic); when every
        // palette color is taken, the least-used one repeats.
        let used = sections.flatMap(\.nodes).compactMap { node -> GroupColor? in
            if case let .group(group) = node { return group.color }
            return nil
        }
        if let free = GroupColor.automatic(used: Set(used.map(\.rawValue))) { return free }
        let palette = GroupColor.allCases.filter { $0 != .grey && $0 != .blue }
        return palette.min { a, b in used.count(where: { $0 == a }) < used.count(where: { $0 == b }) } ?? .purple
    }
}
