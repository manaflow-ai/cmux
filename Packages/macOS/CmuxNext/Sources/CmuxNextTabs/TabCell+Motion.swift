import AppKit
import QuartzCore

// Closing and reorder motion: what a tab shows while it leaves or while
// another tab passes over it (cx-f6i7).
extension TabCell {
    /// The model dropped this tab: it shrinks out from here. Its selection
    /// and hover go at once (the selection moved to another tab in the same
    /// sync), then its content freezes (`closingChanged`).
    func beginClosing() {
        showsSeparator = false
        isHovered = false
        isSelected = false
        isClosing = true
    }

    /// A closing tab keeps the content it showed when the close began while
    /// its width springs to 0: it never switches to the narrow icon-and-x
    /// layout on the way out, and the cell clips what no longer fits.
    func closingChanged() {
        closingVisibility = nil
        if isClosing {
            layoutLayers()
            closingVisibility = visibility
        }
        layer.masksToBounds = isClosing
        layoutLayers()
    }

    /// The lifted tab rides above everything; the selected tab above its
    /// neighbors, so a reorder passes it over them (`occlude(by:)`).
    func updateStacking() {
        layer.zPosition = isLifted ? 10 : isSelected ? 1 : 0
    }

    /// Hides the part of this tab under `cover` (the selected pill passing
    /// over it, in this cell's coordinates): the translucent selection fill
    /// would otherwise show both tabs' content where they cross.
    func occlude(by cover: CGRect?) {
        let visible = cover.flatMap { cover -> CGRect? in
            let cover = cover.intersection(bounds)
            guard !cover.isNull, cover.width > 0 else { return nil }
            let leading = CGRect(x: 0, y: 0, width: cover.minX, height: bounds.height)
            let trailing = CGRect(x: cover.maxX, y: 0, width: max(0, bounds.width - cover.maxX), height: bounds.height)
            return leading.width >= trailing.width ? leading : trailing
        }
        guard let visible else {
            if layer.mask != nil, layer.mask === occlusionMask { layer.mask = nil }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        occlusionMask.backgroundColor = NSColor.black.cgColor
        occlusionMask.frame = visible
        if layer.mask !== occlusionMask { layer.mask = occlusionMask }
        CATransaction.commit()
    }
}

/// A tab crossing under the selected tab (Move Tab Left/Right, a reflow)
/// hides the part under the selected pill. At rest no tab overlaps
/// another, so every mask comes off.
enum TabOcclusion {
    static func apply(cells: [TabID: TabCell], selected: TabID?, in clip: CALayer?) {
        let cover = selected.flatMap { id -> CGRect? in
            guard let cell = cells[id], cell.frame.width > 0 else { return nil }
            return cell.layer.convert(cell.pillFrameInCell, to: clip)
        }
        for (id, cell) in cells where id != selected {
            let crossing = cover.flatMap { cover in !cell.isLifted && cell.frame.intersects(cover) ? cover : nil }
            cell.occlude(by: crossing.map { clip?.convert($0, to: cell.layer) ?? $0 })
        }
    }
}
