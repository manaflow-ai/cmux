public import CoreGraphics
import Foundation

/// Sizes the rail layout reads; filled from `Metrics` at layout time so
/// density and `appearance.borders` changes apply, and fixed in tests.
public nonisolated struct SidebarRailMetrics: Hashable, Sendable {
    /// The rail's width.
    public var width: CGFloat
    /// One square icon button.
    public var buttonSize: CGFloat
    /// Between buttons of one section.
    public var buttonGap: CGFloat
    /// Above and below the line between two sections.
    public var sectionGap: CGFloat
    /// Thickness of a section line: `Metrics.lineWidth`, so 0 under
    /// `appearance.borders = none` (the spacing stays).
    public var lineWidth: CGFloat
    /// A section line's inset from each side of the rail.
    public var lineInset: CGFloat
    /// Space above the first button: below the top row and the traffic
    /// lights.
    public var topInset: CGFloat
    /// Space below the last bottom button.
    public var bottomInset: CGFloat

    public init(width: CGFloat, buttonSize: CGFloat, buttonGap: CGFloat, sectionGap: CGFloat, lineWidth: CGFloat,
                lineInset: CGFloat, topInset: CGFloat, bottomInset: CGFloat) {
        self.width = width
        self.buttonSize = buttonSize
        self.buttonGap = buttonGap
        self.sectionGap = sectionGap
        self.lineWidth = lineWidth
        self.lineInset = lineInset
        self.topInset = topInset
        self.bottomInset = bottomInset
    }
}

/// The rail look (plans/cmux-next/sidebar-sections.md 11): the sidebar's
/// sticky bands drawn as one vertical column of icon buttons beside the
/// sidebar, with no labels and no headers. The band above the workspace
/// list stacks down from the top; the band below it is pinned to the
/// bottom. A line separates sections. A top-band section's `maxRows` caps
/// its buttons (the rest go under the More button, which follows that
/// section's buttons), so the default rail shows four destinations and
/// keeps the rare ones one click away. The Workspaces section stays in the
/// sidebar, and a layout renders as a rail only by switching the look, so
/// the layout document never changes. Pure, so it is tested without views.
/// Coordinates are flipped (y grows down).
public nonisolated struct SidebarRailLayout: Hashable, Sendable {
    /// One placed icon button.
    public struct Button: Hashable, Sendable {
        public var item: LayoutItemID
        public var section: LayoutSectionID
        public var frame: CGRect
    }

    public var buttons: [Button]
    /// Lines between sections, top band then bottom band. Zero height
    /// under `appearance.borders = none`.
    public var separators: [CGRect]
    /// Top-band items under the More button, in document order: items past
    /// their section's `maxRows`, and items that do not fit above the
    /// bottom band.
    public var overflow: [LayoutItemID]
    /// The More button that lists `overflow`: after the first capped
    /// section's buttons, or (when that slot does not fit, or only the
    /// height overflows) in the last top slot that fits, whose own item
    /// moves into the list; nil when nothing overflows or no slot fits.
    public var more: CGRect?
    /// The App's accessory (the update circle), right above the bottom
    /// band; nil when none was asked for.
    public var accessory: CGRect?

    public static let empty = SidebarRailLayout(buttons: [], separators: [], overflow: [], more: nil)

    /// The button under `point`, or nil.
    public func button(at point: CGPoint) -> Button? { buttons.first { $0.frame.contains(point) } }

    /// One band section's items: the ones it shows as buttons, and (top
    /// band) the ones past its `maxRows`.
    struct Column: Hashable, Sendable {
        var section: LayoutSectionID
        var items: [LayoutItemID]
        var capped: [LayoutItemID] = []
    }

    /// - Parameter document: The section layout.
    /// - Parameter room: The room the window shows (room-scoped sections).
    /// - Parameter height: The rail's height.
    /// - Parameter metrics: The sizes.
    /// - Parameter accessory: Whether to keep one button slot above the
    ///   bottom band for the App's accessory.
    /// - Returns: The buttons and lines. The bottom band and the accessory
    ///   always show; capped items and top-band buttons that would reach
    ///   them go under a More button.
    public static func make(document: SidebarLayoutDocument, room: String?, height: CGFloat,
                            metrics m: SidebarRailMetrics, accessory: Bool = false) -> SidebarRailLayout {
        let bands = document.bands(room: room)
        let bottom = stack(columns(bands.below, capsRows: false), moreAfter: nil, metrics: m)
        let bottomTop = height - m.bottomInset - bottom.height
        let bottomButtons = bottom.buttons.map { offset($0, by: bottomTop) }
        let bottomLines = bottom.lines.map { $0.rect.offsetBy(dx: 0, dy: bottomTop) }
        let bandTop = bottomButtons.isEmpty ? height - m.bottomInset : bottomTop - m.buttonGap
        let accessoryFrame = accessory
            ? CGRect(x: ((m.width - m.buttonSize) / 2).rounded(), y: bandTop - m.buttonSize, width: m.buttonSize, height: m.buttonSize)
            : nil

        let topColumns = columns(bands.above, capsRows: true)
        let capped = Set(topColumns.flatMap(\.capped))
        let top = stack(topColumns, moreAfter: topColumns.firstIndex { !$0.capped.isEmpty }, metrics: m)
        let limit = accessoryFrame.map { $0.minY - m.sectionGap }
            ?? (bottomButtons.isEmpty ? height - m.bottomInset : bottomTop - m.sectionGap)
        let topButtons = top.buttons.map { offset($0, by: m.topInset) }
        var kept = topButtons.filter { $0.frame.maxY <= limit }
        var spilled = Set(topButtons.filter { $0.frame.maxY > limit }.map(\.item))
        var more: CGRect?
        var moreSection: LayoutSectionID?
        if let slot = top.more, slot.frame.maxY + m.topInset <= limit {
            more = slot.frame.offsetBy(dx: 0, dy: m.topInset)
            moreSection = slot.section
        }
        // Without its own slot the More button takes the last slot that
        // fits; with no slot (the first one already overflows) the items
        // wait for a taller window.
        if more == nil, !capped.isEmpty || !spilled.isEmpty, let last = kept.popLast() {
            spilled.insert(last.item)
            more = last.frame
            moreSection = last.section
        }
        let overflow = topColumns.flatMap { $0.items + $0.capped }.filter { spilled.contains($0) || capped.contains($0) }
        let keptSections = Set(kept.map(\.section) + [moreSection].compactMap { $0 })
        // A line belongs to the section below it: it shows only while that
        // section keeps a button (the More button counts).
        let topLines = top.lines.filter { keptSections.contains($0.before) }.map { $0.rect.offsetBy(dx: 0, dy: m.topInset) }
        return SidebarRailLayout(buttons: kept + bottomButtons, separators: topLines + bottomLines, overflow: overflow, more: more,
                                 accessory: accessoryFrame)
    }

    /// The item ids each band section shows: item sections only, items this
    /// client renders (unknown kinds render nothing, L5), empty sections
    /// dropped. With `capsRows`, items past a section's `maxRows` are
    /// `capped` instead of shown.
    static func columns(_ sections: [LayoutSection], capsRows: Bool) -> [Column] {
        sections.compactMap { section in
            guard section.content == .items else { return nil }
            let items = section.items.filter { renders($0.ref) }.map(\.id)
            guard !items.isEmpty else { return nil }
            let shown = capsRows ? max(0, min(section.maxRows ?? items.count, items.count)) : items.count
            return Column(section: section.id, items: Array(items.prefix(shown)), capped: Array(items.dropFirst(shown)))
        }
    }

    /// Whether this client draws `ref`: a known kind, and for a built-in a
    /// known id.
    static func renders(_ ref: LayoutItemRef) -> Bool {
        switch ref.kind {
        case LayoutItemRef.builtInKind: ref.builtIn != nil
        case LayoutItemRef.workspaceKind, LayoutItemRef.tabKind, LayoutItemRef.roomKind, LayoutItemRef.savedGroupKind,
             LayoutItemRef.urlKind, LayoutItemRef.appKind: true
        default: false
        }
    }

    /// Stacks `columns` from y 0: buttons centered in the rail, a line
    /// before every section but the first, and the More slot after the
    /// buttons of column `moreAfter`.
    private static func stack(_ columns: [Column], moreAfter: Int?, metrics m: SidebarRailMetrics)
        -> (buttons: [Button], more: (section: LayoutSectionID, frame: CGRect)?, lines: [(before: LayoutSectionID, rect: CGRect)],
            height: CGFloat) {
        let x = ((m.width - m.buttonSize) / 2).rounded()
        var buttons: [Button] = []
        var more: (section: LayoutSectionID, frame: CGRect)?
        var lines: [(before: LayoutSectionID, rect: CGRect)] = []
        var y: CGFloat = 0
        for (index, column) in columns.enumerated() {
            if index > 0 {
                y += m.sectionGap
                lines.append((before: column.section, rect: CGRect(x: m.lineInset, y: y, width: max(0, m.width - 2 * m.lineInset), height: m.lineWidth)))
                y += m.lineWidth + m.sectionGap
            }
            for (row, item) in column.items.enumerated() {
                if row > 0 { y += m.buttonGap }
                buttons.append(Button(item: item, section: column.section, frame: CGRect(x: x, y: y, width: m.buttonSize, height: m.buttonSize)))
                y += m.buttonSize
            }
            if index == moreAfter {
                if !column.items.isEmpty { y += m.buttonGap }
                more = (section: column.section, frame: CGRect(x: x, y: y, width: m.buttonSize, height: m.buttonSize))
                y += m.buttonSize
            }
        }
        return (buttons, more, lines, y)
    }

    private static func offset(_ button: Button, by dy: CGFloat) -> Button {
        var moved = button
        moved.frame = moved.frame.offsetBy(dx: 0, dy: dy)
        return moved
    }
}
