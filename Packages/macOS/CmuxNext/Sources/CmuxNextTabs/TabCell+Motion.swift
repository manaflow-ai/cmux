import AppKit
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
        layer.masksToBounds = isClosing || clipsMotion
        layoutLayers()
    }

    /// The lifted tab rides above everything; the selected tab above its
    /// neighbors, so a reorder passes it over them (`occlude(by:)`).
    func updateStacking() {
        // Below group chips (1), above the other tabs.
        layer.zPosition = isLifted ? 10 : isSelected ? 0.5 : 0
    }

    /// Hides the part of this tab under `cover` (the selected pill passing
    /// over it, in this cell's coordinates): the translucent selection fill
    /// would otherwise show both tabs' content where they cross.
    /// `always`: `cover` is the visible part itself (a move's last keyframe), kept even when it is the whole tab.
    func occlude(by cover: CGRect?, always: Bool = false) {
        let visible = always ? cover : cover.flatMap { TabOcclusion.visible(frame: CGRect(origin: .zero, size: bounds.size), cover: $0) }
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
    /// Where a cell and its pill show now, in its layer's coordinates: a move starts there.
    struct Shown {
        var frame: CGRect
        var pill: CGRect
    }

    /// Samples along a move: a mask's path is straight between them (the cover enters, then flips sides).
    static let samples = 12

    /// Every cell's frame and pill as on screen now (presentation layers, every move in flight included).
    @MainActor
    static func start(cells: [TabID: TabCell]) -> [TabID: Shown] {
        cells.mapValues { cell in
            Shown(frame: (cell.layer.presentation() ?? cell.layer).frame,
                  pill: (cell.backgroundLayer.presentation() ?? cell.backgroundLayer).frame)
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
    static func crosses(_ cell: TabCell, _ id: TabID, selected: TabID, cover: TabCell, band: CGFloat) -> Bool {
        id != selected && !cell.isLifted && (band <= 0 || cell.item.isPinned == cover.item.isPinned)
    }

    /// At rest: the tabs under the selected pill now hide that part; the others show whole. `skipping`:
    /// tabs whose mask a move animates (`animate`), left as they are.
    @MainActor
    static func apply(cells: [TabID: TabCell], selected: TabID?, in clip: CALayer?, band: CGFloat = 0, skipping: (TabID) -> Bool = { _ in false }) {
        let cover = selected.flatMap { id -> (cell: TabCell, rect: CGRect)? in
            guard let cell = cells[id], cell.frame.width > 0 else { return nil }
            return (cell, cell.layer.convert(cell.pillFrameInCell, to: clip))
        }
        for (id, cell) in cells where !skipping(id) {
            // The selected tab itself is never covered, even one selected mid-crossing.
            let crossing = cover.flatMap { cover -> CGRect? in
                guard let selected, crosses(cell, id, selected: selected, cover: cover.cell, band: band), cell.frame.intersects(cover.rect) else { return nil }
                return clip?.convert(cover.rect, to: cell.layer) ?? cover.rect
            }
            cell.occlude(by: crossing)
        }
    }

    /// A move: each tab the selected pill crosses on the way (from `start`, where everything showed,
    /// to the frames now) hides the part under it, as keyframes along the move's progress; the mask
    /// comes off when the move ends (`TabStripView.moveEnded`). The two run on one curve from one
    /// frame, so their frames are straight lines in that progress. Approximate where an earlier move
    /// still runs under this one (the path is then the sum of two curves) or the selection changes
    /// before the move ends (the crossed tabs keep the old pill's mask until then). Returns the tabs it masks.
    @MainActor
    static func animate(cells: [TabID: TabCell], selected: TabID?, band: CGFloat, from start: [TabID: Shown], move: TabStripMove) -> Set<TabID> {
        guard let selected, let cover = cells[selected], let coverStart = start[selected] else { return [] }
        let coverEnd = Shown(frame: cover.frame, pill: cover.pillFrameInCell)
        func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
            CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                   width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
        }
        func pill(_ shown: Shown) -> CGRect { shown.pill.offsetBy(dx: shown.frame.minX, dy: shown.frame.minY) }
        var masked: Set<TabID> = []
        for (id, cell) in cells {
            // Both layers (tabsClip's, the scrolling layer) have the clip's coordinates.
            guard crosses(cell, id, selected: selected, cover: cover, band: band), let from = start[id] else { continue }
            var rects: [CGRect] = []
            var crossed = false
            for step in 0...samples {
                let t = CGFloat(step) / CGFloat(samples)
                let frame = lerp(from.frame, cell.frame, t)
                let rect = visible(frame: frame, cover: lerp(pill(coverStart), pill(coverEnd), t))
                crossed = crossed || rect != nil
                rects.append(rect ?? CGRect(origin: .zero, size: frame.size))
            }
            guard crossed, let last = rects.last,
                  let positions = move.motion.keyframes("position", values: rects.map { NSValue(point: CGPoint(x: $0.midX, y: $0.midY)) }),
                  let sizes = move.motion.keyframes("bounds.size", values: rects.map { NSValue(size: $0.size) }) else { continue }
            cell.occlude(by: last, always: true)
            move.add(positions, to: cell.occlusionMask, as: "occlusion.position")
            move.add(sizes, to: cell.occlusionMask, as: "occlusion.size")
            masked.insert(id)
        }
        return masked
    }
}
