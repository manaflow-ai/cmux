import CoreGraphics
import Foundation

/// Drop-to-pin (PINNED-ITEMS-END-TO-END P2): where a workspace row dragged
/// from the list lands in the band above it. The items section under the
/// point (its header, its rows or tiles, half a section gap around them)
/// takes it, at the index of the first item the point is not past (never
/// before the section's leading built-in rows); past every item, it goes
/// last. Pure, read from the band's layout.
nonisolated struct SidebarRegionDrop: Hashable, Sendable {
    var section: LayoutSectionID
    var index: Int
    /// The section's frame in the band (the outline the drag shows).
    var frame: CGRect

    /// The drop under `point` (band coordinates), or nil when the point is
    /// over no items section of `sections` (an app section takes no rows).
    static func target(at point: CGPoint, layout: SidebarRegionLayout, sections: [LayoutSection], gap: CGFloat) -> SidebarRegionDrop? {
        for section in sections where section.content == .items {
            let rows = layout.rows.filter { Self.section(of: $0) == section.id }
            guard let first = rows.first else { continue }
            let frame = rows.dropFirst().reduce(first.frame) { $0.union($1.frame) }.insetBy(dx: 0, dy: -gap / 2)
            guard point.y >= frame.minY, point.y < frame.maxY else { continue }
            let next = rows.first { row in Self.item(of: row) != nil && !Self.isPast(point, row) }
            let index = next.flatMap(Self.item).flatMap { id in section.items.firstIndex { $0.id == id } } ?? section.items.count
            // The built-in rows (Home, App Store) stay at the top of their
            // section: a pin goes after them (cx-odqn, coordinator 2026-10-08).
            let builtIns = section.items.prefix { $0.ref.kind != LayoutItemRef.workspaceKind }.count
            return SidebarRegionDrop(section: section.id, index: max(index, builtIns), frame: frame)
        }
        return nil
    }

    /// Whether `point` is past `row` in reading order: below a list row's
    /// middle, or beside or below a tile or chip on its line.
    private static func isPast(_ point: CGPoint, _ row: SidebarRegionRow) -> Bool {
        switch row.kind {
        case .tile, .chip:
            if point.y >= row.frame.maxY { return true }
            return point.y >= row.frame.minY && point.x >= row.frame.midX
        default:
            return point.y >= row.frame.midY
        }
    }

    private static func section(of row: SidebarRegionRow) -> LayoutSectionID? {
        switch row.kind {
        case let .header(id), let .app(id): id
        case let .item(_, id), let .tile(_, id), let .chip(_, id): id
        }
    }

    private static func item(of row: SidebarRegionRow) -> LayoutItemID? {
        switch row.kind {
        case let .item(id, _), let .tile(id, _), let .chip(id, _): id
        case .header, .app: nil
        }
    }
}
