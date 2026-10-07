import AppKit
import CmuxNextDesign

// `sidebar.spacesPosition` (R109): the spaces dots sit in the footer row,
// right after the profile control (SIDEBAR-FOOTER-AND-SPACE-MENU amendment
// 3: one row, avatar leading, dots after it, anchored leading), or in their
// own row under the titlebar row.
extension SidebarView {
    /// The footer band has items, so the dots go in its first row.
    var dotsShareBandRow: Bool {
        model.layout.sections.contains { $0.region == .bottom && !$0.items.isEmpty }
    }

    /// The footer band's first row in this view's coordinates: its frame
    /// across the row, and where its items end. Nil when the band shows none.
    var bandFirstRow: (frame: NSRect, itemsMaxX: CGFloat)? {
        let items = belowRegion.layoutResult.rows.filter {
            switch $0.kind {
            case .tile, .chip: true
            default: false
            }
        }
        guard let first = items.min(by: { $0.frame.minY < $1.frame.minY }) else { return nil }
        let line = items.filter { abs($0.frame.minY - first.frame.minY) < 0.5 }
        let frame = convert(first.frame, from: belowRegion)
        let maxX = line.map { convert($0.frame, from: belowRegion).maxX }.max() ?? frame.maxX
        return (frame, maxX)
    }

    /// Puts the dots in their row at `top` (`height` > 0), after the footer
    /// band's items in its first row, or in the footer when the band is empty.
    func placeSpaces(top: CGFloat, height: CGFloat) {
        if spacesPosition == .top {
            if profileBar.superview !== self { addSubview(profileBar) }
            profileBar.leadingInset = nil
            profileBar.frame = NSRect(x: 0, y: top, width: bounds.width, height: height)
        } else if false, let row = bandFirstRow {
            if profileBar.superview !== self { addSubview(profileBar) }
            // The dots start right after the control; their slots carry the gap.
            profileBar.leadingInset = 0
            profileBar.frame = NSRect(x: row.itemsMaxX, y: row.frame.minY, width: max(0, bounds.width - row.itemsMaxX), height: row.frame.height)
        } else {
            if profileBar.superview !== footer { footer.addSubview(profileBar) }
            profileBar.leadingInset = nil
            profileBar.frame = NSRect(x: 0, y: 0, width: footer.bounds.width, height: footer.bounds.height)
        }
        profileBar.refresh()
    }
}
