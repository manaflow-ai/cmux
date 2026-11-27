import AppKit
import CmuxNextDesign
import CmuxVisibleRows

extension SidebarRegionView {
    /// Icon + label width of every item of an inline section. The profile
    /// control is the avatar alone, never a labeled chip (Leo and Lawrence 2026-10-20).
    static func labelWidths(_ content: Content, width: CGFloat, meter: ListWorkMeter? = nil) -> [LayoutItemID: CGFloat] {
        var widths: [LayoutItemID: CGFloat] = [:]
        let font = SidebarStyle.titleFont
        // Inline lines and span grids (R53) draw labeled items with icon and label.
        for section in content.sections where section.arrangement.layout == .inline
            || (section.arrangement.layout == .grid && section.items.contains { $0.span != nil }) {
            for item in section.items {
                let info = content.infos[item.id] ?? .fallback(for: item)
                if info.avatar == nil, item.showsLabel {
                    widths[item.id] = SidebarItemRowView.chipWidth(title: info.title, font: font, badge: info.badge, dot: info.unreadDot,
                                                                   activity: info.activity != .idle, meter: meter)
                }
            }
        }
        return widths
    }

    /// Up and Down from a focused item walk the whole sidebar (`SidebarArrowWalk`).
    override func keyDown(with event: NSEvent) {
        if let item = window?.firstResponder as? SidebarItemRowView, SidebarArrowWalk.step(from: item, event) { return }
        super.keyDown(with: event)
    }

    /// Edit mode on an item: never on a client-only item (What's New) or a drag's gap.
    func edit(_ view: SidebarItemRowView, _ id: LayoutItemID) {
        view.isEditing = isEditing && !id.isTransient && id != SidebarListBlocks.gapID
    }

    /// A band in its capped scroll view: only the items `scroll` shows and the list's overscan past each edge get views
    /// (as a list block's do), and a scroll or a resize of the band realizes the items it brings in and lets the far
    /// ones go. A band of 10,000 pinned items makes the screenful it shows, not 10,000. Call before the region is the
    /// scroll view's document: the band's clip view (`SidebarBandClipView`) reports each move.
    func realizesItems(in scroll: NSScrollView) {
        let clip = SidebarBandClipView()
        clip.onMove = { [weak self] in self?.realizeItems() }
        scroll.contentView = clip
        itemWindow = { [weak self, weak clip] in
            guard let self, let clip else { return nil }
            // Before the band has its height (a new window's first update): the first screenful, where a band starts.
            let visible = clip.bounds.height > 0 ? convert(clip.bounds, from: clip)
                : NSRect(x: 0, y: 0, width: bounds.width, height: window?.frame.height ?? NSScreen.main?.frame.height ?? 1_000)
            // The list's overscan past each edge, never more than one band's height (a short band keeps a short window).
            let span = RowSpans.mountWindow(visibleMinY: Double(visible.minY), visibleHeight: Double(visible.height),
                                            overscan: Double(SidebarStyle.overscan))
            return NSRect(x: -1e6, y: span.lowerBound, width: 2e6, height: span.upperBound - span.lowerBound)
        }
    }

    /// Gives the first or the last item a view wherever the band is scrolled: the arrow walk's step from the list
    /// into the band focuses it, and the focus scrolls to it.
    func realizeEdgeItem(last: Bool) {
        guard let content else { return }
        let rows = layoutResult.rows, shown = displayed(content)
        for index in stride(from: last ? rows.count - 1 : 0, through: last ? 0 : rows.count - 1, by: last ? -1 : 1) {
            switch rows[index].kind {
            case let .item(id, sectionID), let .tile(id, sectionID), let .chip(id, sectionID):
                guard itemViews[id] == nil, let section = shown.sections.first(where: { $0.id == sectionID }) else { return }
                _ = showItem(rows[index], id, section, shown)
                return
            default: continue
            }
        }
    }
}

/// A band's clip view: it reports each move of what the band shows (a wheel, a scroller drag, a programmatic scroll, a
/// resize), so the band's items realize with it (`SidebarRegionView.realizesItems(in:)`).
final class SidebarBandClipView: NSClipView {
    var onMove: (() -> Void)?

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        onMove?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onMove?()
    }
}

/// A band or a list block under the visible-rows contract (`VisibleRowsContract`): an item given new content, an item
/// placed at its frame, a label measured, and the items each layout reads count on `listWork`.
extension SidebarRegionView: VisibleRowsList {
    /// Item views in the region: the region keeps no parked ones.
    var rowViewsAlive: Int { itemViews.count }
}
