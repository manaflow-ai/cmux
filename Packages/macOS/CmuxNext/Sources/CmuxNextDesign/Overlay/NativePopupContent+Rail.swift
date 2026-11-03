import AppKit

/// The rail's four placements, as the web picker's harness placements lay them out
/// (modelPicker.css `.acpmux-quick-placement-*`). The page chooses the placement, the tabs, their
/// marks and which one is checked; this only lays them out.
extension NativePopupContent {
    func makeRailTab(_ row: NativePopupRow, placement: NativePopupRailPlacement) -> NSView {
        let tab = NativePopupRailTab(row: row, placement: placement)
        tab.onActivate = { [weak self, weak tab] in
            guard let self, let tab else { return }
            activate(row, view: tab)
        }
        return tab
    }

    /// The tabs go into the wrapping strip (symbols, top) or straight into the popup (left, compact).
    /// `rail` is the incoming model's: `model` still holds the replaced one while rows rebuild.
    func addPlacedRail(_ placement: NativePopupRailPlacement, rail: Set<String>) {
        let divider = NSBox.separator()
        railDivider = divider
        addSubview(divider)
        if placement == .symbols || placement == .top {
            let strip = NSScrollView()
            strip.drawsBackground = false
            strip.borderType = .noBorder
            strip.hasVerticalScroller = false
            strip.hasHorizontalScroller = false
            strip.horizontalScrollElasticity = .none
            strip.verticalLineScroll = PopupStyle.standard.rowHeight + (placement == .symbols ? Metrics.space1 : 0)
            let document = NativePopupRailStripDocument()
            strip.documentView = document
            railStrip = strip
            addSubview(strip)
            for (row, view) in rowViews where rail.contains(row.id) { document.addSubview(view) }
        } else {
            for (row, view) in rowViews where rail.contains(row.id) { addSubview(view) }
        }
        for (row, view) in rowViews where !rail.contains(row.id) { addSubview(view) }
    }

    /// Lays out the title, the search field across the top, the rail in its placement, the list
    /// and the footer; returns the content height.
    func layoutPlacedRail(_ placement: NativePopupRailPlacement, title: NSView?, search: NSView?) -> CGFloat {
        let inset = PopupStyle.standard.padding
        let width = bounds.width
        let rail = railIDs
        let footer = Set((model?.footer ?? []).map(\.id))
        let hairline = max(Metrics.lineWidth(0.5), 0)
        var y = inset
        if let title { title.frame = NSRect(x: inset + 7, y: y, width: max(0, width - inset * 2 - 14), height: 24); y += 24 }
        if let search { search.frame = NSRect(x: inset + 4, y: y, width: max(0, width - inset * 2 - 8), height: 28); y += 34 }
        let tabs = rowViews.filter { rail.contains($0.0.id) }.compactMap { $0.1 as? NativePopupRailTab }
        var bodyX = inset
        var listTop = y
        var railBottom = y
        switch placement {
        case .symbols, .top:
            let strip = railStrip
            let pad = placement == .symbols ? Metrics.space2 : Metrics.space1
            let gap = placement == .symbols ? Metrics.space1 : 0
            var x = pad, line = pad, lineHeight: CGFloat = 0
            for tab in tabs {
                let size = tab.preferredSize(available: max(0, width - pad * 2))
                if x > pad, x + size.width > width - pad { x = pad; line += lineHeight + gap; lineHeight = 0 }
                tab.frame = NSRect(origin: NSPoint(x: x, y: line), size: size)
                x += size.width + gap
                lineHeight = max(lineHeight, size.height)
            }
            // The symbols row's bottom inset is one gap, so a fourth row starts where three end.
            let total = line + lineHeight + (placement == .symbols ? gap : pad)
            let limit = placement == .symbols ? pad + 3 * PopupStyle.standard.rowHeight + 3 * gap : 132
            let height = min(total, limit)
            strip?.frame = NSRect(x: 0, y: y, width: width, height: height)
            strip?.documentView?.frame = NSRect(x: 0, y: 0, width: width, height: total)
            railDivider?.frame = NSRect(x: 0, y: y + height, width: width, height: hairline)
            listTop = y + height + hairline
            railBottom = listTop
        case .left, .compact:
            let column = CGFloat(model?.railWidth ?? (placement == .compact ? 68 : (width * 0.36).rounded()))
            var tabY = y + Metrics.space1
            for tab in tabs {
                let size = tab.preferredSize(available: max(0, column - Metrics.space1 * 2))
                tab.frame = NSRect(origin: NSPoint(x: Metrics.space1, y: tabY), size: size)
                tabY += size.height
            }
            railBottom = tabY + Metrics.space1
            bodyX = column + hairline + inset
        }
        let bodyWidth = max(0, width - bodyX - inset)
        var rowY = listTop
        for (row, view) in rowViews where !rail.contains(row.id) && !footer.contains(row.id) {
            let height = rowHeight(row, view: view)
            view.frame = NSRect(x: bodyX, y: rowY, width: bodyWidth, height: height)
            rowY += height
        }
        if placement == .left || placement == .compact {
            let column = bodyX - inset - hairline
            railDivider?.frame = NSRect(x: column, y: y, width: hairline, height: max(rowY, railBottom) - y)
        }
        var bottom = max(rowY, railBottom)
        for (row, view) in rowViews where footer.contains(row.id) {
            let height = rowHeight(row, view: view)
            view.frame = NSRect(x: inset, y: bottom, width: max(0, width - inset * 2), height: height)
            bottom += height
        }
        // The checked tab stays in view in a strip past its row limit, once per change of tab.
        let checked = tabs.first { $0.isSelected }
        if checked?.row.id != lastCheckedRail {
            lastCheckedRail = checked?.row.id
            if let checked, checked.superview !== self { checked.scrollToVisible(checked.bounds) }
        }
        return bottom + inset
    }

    private func rowHeight(_ row: NativePopupRow, view: NSView) -> CGFloat {
        (view as? NativePopupSliderView)?.preferredHeight
            ?? (row.kind == .separator ? 9 : row.kind == .textField ? 32 : row.description?.isEmpty == false ? 44 : PopupStyle.standard.rowHeight)
    }
}

/// The wrapping strip's flipped document: its rows run top down.
@MainActor
final class NativePopupRailStripDocument: NSView {
    override var isFlipped: Bool { true }
}
