import AppKit
import CmuxNextDesign
import QuartzCore

// Closing and reorder motion: what a tab shows while it leaves or while
// another tab passes over it (cx-f6i7).
extension TabCell {
    /// The model dropped this tab: it shrinks out from here. Its selection
    /// and hover go at once (the selection moved to another tab in the same
    /// sync), then its content freezes (`closingChanged`).
    func beginClosing() {
        isHovered = false
        isSelected = false
        showsZoom = false // the zoom indicator goes to the new selection
        isMultiSelected = false
        showsSeparator = false
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
    /// neighbors, so a reorder passes it over them (`occlude(visible:)`).
    func updateStacking() {
        // Below group chips (1), above the other tabs.
        layer.zPosition = isLifted ? 10 : isSelected ? 0.5 : 0
    }

    /// Shows only `visible` (this cell's coordinates) of the tab: the rest is under the selected pill,
    /// whose translucent fill would otherwise show both tabs' content where they cross. nil: all of it.
    func occlude(visible: CGRect?) {
        for key in TabOcclusion.keys { occlusionMaskIfMade?.removeAnimation(forKey: key) }
        guard let visible else {
            if layer.mask != nil, layer.mask === occlusionMaskIfMade { layer.mask = nil }
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

/// A tab crossing under the selected tab (Move Tab Left/Right, a reflow, an open or a close)
/// hides the part under the selected pill. At rest no tab overlaps another, so every mask comes off.
enum TabOcclusion {
    static let keys = ["tab.occlusion.position", "tab.occlusion.size"]

    /// A cell's frame on screen at any time: its model plus every strip move in flight (`MotionPath`;
    /// the root's anchor is its origin).
    struct Path {
        let position: MotionPath
        let size: MotionPath

        @MainActor
        init(_ cell: TabCell, now: CFTimeInterval) {
            position = MotionPath(cell.layer, "position", now: now)
            size = MotionPath(cell.layer, "bounds.size", now: now)
        }

        var end: CFTimeInterval { max(position.end ?? -.infinity, size.end ?? -.infinity) }

        func frame(at time: CFTimeInterval) -> CGRect {
            let origin = position.value(at: time), size = size.value(at: time)
            return CGRect(x: origin.x, y: origin.y, width: max(0, size.x), height: max(0, size.y))
        }
    }

    /// The part of a cell `frame` wide to keep visible under `cover` (both in the cell's layer), in the
    /// cell's coordinates: the larger side the pill leaves; nil when the pill does not cover it.
    static func visible(frame: CGRect, cover: CGRect) -> CGRect? {
        let cover = cover.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(CGRect(origin: .zero, size: frame.size))
        guard !cover.isNull, cover.width > 0 else { return nil }
        let leading = CGRect(x: 0, y: 0, width: cover.minX, height: frame.height)
        let trailing = CGRect(x: cover.maxX, y: 0, width: max(0, frame.width - cover.maxX), height: frame.height)
        return leading.width >= trailing.width ? leading : trailing
    }

    /// `band`: the fixed pinned band (`TabScrollMapping.band`). With one, pinned and unpinned tabs never
    /// cross (the unpinned ones scroll under the band, clipped), so a pill covers only its own region's tabs.
    /// Both regions' layers (tabsClip's, the scrolling layer) have the clip's coordinates.
    static func crosses(_ cell: TabCell, _ id: TabID, selected: TabID, cover: TabCell, band: CGFloat) -> Bool {
        id != selected && !cell.isLifted && (band <= 0 || cell.item.isPinned == cover.item.isPinned)
    }

    /// Masks every tab the selected pill covers, now and along every move in flight: a tab that
    /// moves under it (or that it moves over) hides the part under the pill frame by frame until the
    /// last move ends, sampled from the paths as the render server shows them, so a move that starts
    /// over a running one and a selection that changes mid-move are exact. Call after a change added
    /// its moves (same transaction) and when the selection changes. Returns, per masked tab, when its
    /// keyframes end (then the strip calls this again: at rest no mask is left).
    @MainActor
    /// `settle`: a path that ends within it counts as ended (the strip's move completion).
    static func update(cells: [TabID: TabCell], selected: TabID?, band: CGFloat, settle: CFTimeInterval = 0.001) -> [TabID: CFTimeInterval] {
        let now = CACurrentMediaTime()
        guard let selected, let cover = cells[selected], cover.frame.width > 0 else {
            for cell in cells.values { cell.occlude(visible: nil) }
            return [:]
        }
        let coverPath = Path(cover, now: now)
        let height = cover.layer.bounds.height
        func pill(_ frame: CGRect) -> CGRect {
            cover.metrics.pillFrame(slotWidth: frame.width, height: height).offsetBy(dx: frame.minX, dy: frame.minY)
        }
        var masked: [TabID: CFTimeInterval] = [:]
        for (id, cell) in cells {
            guard crosses(cell, id, selected: selected, cover: cover, band: band) else {
                cell.occlude(visible: nil)
                continue
            }
            let path = Path(cell, now: now)
            let end = max(coverPath.end, path.end)
            guard end > now + settle else {
                cell.occlude(visible: visible(frame: cell.frame, cover: pill(cover.frame)))
                continue
            }
            let times = MotionPath.times(from: now, to: end, count: MotionPath.sampleCount(seconds: end - now))
            var crossed = false
            let rects = times.enumerated().map { index, time -> CGRect in
                let last = index == times.count - 1
                let frame = last ? cell.frame : path.frame(at: time)
                let rect = visible(frame: frame, cover: pill(last ? cover.frame : coverPath.frame(at: time)))
                crossed = crossed || rect != nil
                return rect ?? CGRect(origin: .zero, size: frame.size)
            }
            guard crossed, let last = rects.last else {
                cell.occlude(visible: nil)
                continue
            }
            cell.occlude(visible: last)
            let mask = cell.occlusionMask
            if let positions = MotionPath.keyframes("position", values: rects.map { NSValue(point: CGPoint(x: $0.midX, y: $0.midY)) }, times: times, on: mask) {
                mask.add(positions, forKey: keys[0])
            }
            if let sizes = MotionPath.keyframes("bounds.size", values: rects.map { NSValue(size: $0.size) }, times: times, on: mask) {
                mask.add(sizes, forKey: keys[1])
            }
            masked[id] = end
        }
        return masked
    }
}
