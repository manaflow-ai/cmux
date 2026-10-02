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
/// bottom. A line separates sections. The Workspaces section stays in the
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
    /// Top-band items that do not fit above the bottom band, in order.
    public var overflow: [LayoutItemID]
    /// The More button that lists `overflow`, in the last top slot that
    /// fits (its own item moves into the list); nil when nothing overflows
    /// or no slot fits.
    public var more: CGRect?

    public static let empty = SidebarRailLayout(buttons: [], separators: [], overflow: [], more: nil)

    /// The button under `point`, or nil.
    public func button(at point: CGPoint) -> Button? { buttons.first { $0.frame.contains(point) } }

    /// - Parameter document: The section layout.
    /// - Parameter room: The room the window shows (room-scoped sections).
    /// - Parameter height: The rail's height.
    /// - Parameter metrics: The sizes.
    /// - Returns: The buttons and lines. The bottom band always shows;
    ///   top-band buttons that would reach it overflow into a More button.
    public static func make(document: SidebarLayoutDocument, room: String?, height: CGFloat,
                            metrics m: SidebarRailMetrics) -> SidebarRailLayout {
        let bands = document.bands(room: room)
        let bottom = stack(columns(bands.below), metrics: m)
        let bottomTop = height - m.bottomInset - bottom.height
        let bottomButtons = bottom.buttons.map { offset($0, by: bottomTop) }
        let bottomLines = bottom.lines.map { $0.rect.offsetBy(dx: 0, dy: bottomTop) }

        let top = stack(columns(bands.above), metrics: m)
        let limit = bottomButtons.isEmpty ? height - m.bottomInset : bottomTop - m.sectionGap
        let topButtons = top.buttons.map { offset($0, by: m.topInset) }
        var kept = topButtons.filter { $0.frame.maxY <= limit }
        var overflow = topButtons.filter { $0.frame.maxY > limit }.map(\.item)
        var more: CGRect?
        var moreSection: LayoutSectionID?
        // The More button takes the last slot that fits; with no slot (the
        // first one already overflows) the items wait for a taller window.
        if !overflow.isEmpty, let last = kept.popLast() {
            overflow.insert(last.item, at: 0)
            more = last.frame
            moreSection = last.section
        }
        let keptSections = Set(kept.map(\.section) + [moreSection].compactMap { $0 })
        // A line belongs to the section below it: it shows only while that
        // section keeps a button (the More button counts).
        let topLines = top.lines.filter { keptSections.contains($0.before) }.map { $0.rect.offsetBy(dx: 0, dy: m.topInset) }
        return SidebarRailLayout(buttons: kept + bottomButtons, separators: topLines + bottomLines, overflow: overflow, more: more)
    }

    /// The item ids each band section shows: item sections only, items this
    /// client renders (unknown kinds render nothing, L5), empty sections
    /// dropped.
    static func columns(_ sections: [LayoutSection]) -> [(section: LayoutSectionID, items: [LayoutItemID])] {
        sections.compactMap { section in
            guard section.content == .items else { return nil }
            let items = section.items.filter { renders($0.ref) }.map(\.id)
            return items.isEmpty ? nil : (section: section.id, items: items)
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
    /// before every section but the first.
    private static func stack(_ columns: [(section: LayoutSectionID, items: [LayoutItemID])], metrics m: SidebarRailMetrics)
        -> (buttons: [Button], lines: [(before: LayoutSectionID, rect: CGRect)], height: CGFloat) {
        let x = ((m.width - m.buttonSize) / 2).rounded()
        var buttons: [Button] = []
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
        }
        return (buttons, lines, y)
    }

    private static func offset(_ button: Button, by dy: CGFloat) -> Button {
        var moved = button
        moved.frame = moved.frame.offsetBy(dx: 0, dy: dy)
        return moved
    }
}
