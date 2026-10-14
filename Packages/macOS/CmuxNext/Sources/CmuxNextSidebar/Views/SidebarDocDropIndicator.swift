import AppKit
import CmuxNextDesign

// One drop look for every section of the sidebar document (sidebar-v2 S5):
// every drag (a list row, a group, a link row, a Pinned or custom tile) is
// hit-tested by the same `SidebarDragGeometry` against the acceptance table
// of its one `drag_begin`, over the list and over the band, and shows its
// drop the same way wherever it is:
// - a list section (machine lists, the groups of Pinned and custom
//   sections): the gap the list opens at the drop (`gap`), or the group
//   header's drop fill (`into`);
// - a tile or a row of the band (Pinned and custom tiles): the insertion
//   line at the drop (`line`);
// - a refused place: no gap, no line, the lift turns refused (`refused`).
// The band's own reorder preview and the drop outline do not run on the document.

extension SidebarDocDrag {
    /// The band's slots in band coordinates: a tile or chip on its line, a
    /// row, a section header (the drop goes first in it). Client-only items
    /// (What's New) and app sections take no drop.
    func bandGeometry(_ layout: SidebarRegionLayout, acceptance: [String: SidebarDocAcceptance]) -> SidebarDragGeometry {
        var slots: [SidebarDragGeometry.Slot] = []
        for row in layout.rows {
            switch row.kind {
            case let .header(section):
                slots.append(.init(key: section.rawValue, item: nil, section: section.rawValue, frame: row.frame, kind: .section))
            case let .item(id, section) where !id.isTransient:
                slots.append(.init(key: id.rawValue, item: id.rawValue, section: section.rawValue, frame: row.frame, kind: .row))
            case let .tile(id, section) where !id.isTransient:
                slots.append(.init(key: id.rawValue, item: id.rawValue, section: section.rawValue, frame: row.frame, kind: .tile))
            case let .chip(id, section) where !id.isTransient:
                slots.append(.init(key: id.rawValue, item: id.rawValue, section: section.rawValue, frame: row.frame, kind: .tile))
            default:
                continue
            }
        }
        return SidebarDragGeometry(slots: slots, acceptance: acceptance)
    }
}

extension SidebarDragGeometry.Hit {
    /// The insertion line of a band hit (in the slot's coordinates): across
    /// a row's edge, beside a tile, under a section header.
    var lineFrame: CGRect {
        let frame = slot.frame, thickness = SidebarDropLineView.thickness
        switch (slot.kind, zone) {
        case (.tile, .before): return CGRect(x: frame.minX - thickness, y: frame.minY, width: thickness, height: frame.height)
        case (.tile, _): return CGRect(x: frame.maxX, y: frame.minY, width: thickness, height: frame.height)
        case (_, .before): return CGRect(x: frame.minX, y: frame.minY - thickness / 2, width: frame.width, height: thickness)
        default: return CGRect(x: frame.minX, y: frame.maxY - thickness / 2, width: frame.width, height: thickness)
        }
    }
}

/// The band's insertion line over the sidebar; it takes no mouse and is added on first use.
final class SidebarDropLineView: NSView {
    static let thickness: CGFloat = 2
    private let line = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        line.cornerRadius = Self.thickness / 2
        line.isHidden = true
        layer?.addSublayer(line)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(line.isHidden || !Motion.animatesMovement)
        line.frame = rect
        line.isHidden = false
        performWithTheme { line.backgroundColor = Palette.accent.cgColor }
        CATransaction.commit()
    }

    func hide() { line.isHidden = true }

    /// The line shows now (debug).
    var isShown: Bool { !line.isHidden }
}

extension SidebarView {
    /// Shows the band's insertion line for `hit` (a slot of `region`).
    func showDropLine(_ hit: SidebarDragGeometry.Hit, in region: SidebarRegionView) {
        let overlay = subviews.lazy.compactMap { $0 as? SidebarDropLineView }.first ?? {
            let view = SidebarDropLineView(frame: bounds)
            addSubview(view, positioned: .above, relativeTo: nil)
            return view
        }()
        if overlay !== subviews.last { addSubview(overlay, positioned: .above, relativeTo: nil) }
        overlay.show(overlay.convert(region.convert(hit.lineFrame, to: nil), from: nil))
    }

    func hideDropLine() {
        subviews.lazy.compactMap { $0 as? SidebarDropLineView }.first?.hide()
    }

    /// The band hit under `windowPoint` for a drag with `acceptance`; nil
    /// when the point is not over the band above the list. Only that band:
    /// the band below draws no sections (cx-n0i9), only the footer row.
    func bandHit(at windowPoint: NSPoint, doc: SidebarDocDrag, acceptance: [String: SidebarDocAcceptance]) -> SidebarDragGeometry.Hit? {
        let scroll = aboveScroll
        guard !scroll.isHidden, scroll.bounds.contains(scroll.convert(windowPoint, from: nil)) else { return nil }
        return doc.bandGeometry(aboveRegion.layoutResult, acceptance: acceptance).hit(aboveRegion.convert(windowPoint, from: nil))
    }

    /// Whether `windowPoint` is over the list's scroll view.
    func isOverList(_ windowPoint: NSPoint) -> Bool {
        guard let scroll = list.enclosingScrollView else { return false }
        return scroll.bounds.contains(scroll.convert(windowPoint, from: nil))
    }
}

/// A band item's drag on the document (`SidebarRegionView.docDrag`): the
/// item, its acceptance table (one `drag_begin`), the list geometry built
/// once, and the move its drop makes.
@MainActor final class SidebarDocBandDrag {
    let item: String
    let acceptance: [String: SidebarDocAcceptance]
    var listGeometry: (SidebarDragGeometry, [String: SidebarRow])?
    var target: SidebarDocTarget?
    var probe: SidebarDropProbe?

    init(item: String, acceptance: [String: SidebarDocAcceptance]) {
        self.item = item
        self.acceptance = acceptance
    }

    /// The drag moved to `windowPoint` over `sidebar`: the list shows a gap
    /// or a group fill, the band a line, as the hit says.
    func update(_ sidebar: SidebarView, doc: SidebarDocDrag, at windowPoint: NSPoint) {
        let list = sidebar.list
        if sidebar.isOverList(windowPoint) {
            sidebar.hideDropLine()
            if listGeometry == nil {
                let base = SidebarLayout.make(sections: list.model.sections, metrics: list.metrics, options: list.options(includeGap: false))
                listGeometry = doc.geometry(base, width: list.bounds.width, acceptance: acceptance)
            }
            guard let (geometry, rows) = listGeometry else { return }
            let point = list.convert(windowPoint, from: nil)
            let y = SidebarDragGeometry.baseY(displayY: point.y, gapY: list.displayed.gapY, gapHeight: list.displayed.gapShift)
            let hit = geometry.hit(CGPoint(x: point.x, y: y))
            target = hit?.target
            list.bandDrop = hit.flatMap { hit in hit.target == nil ? nil : rows[hit.slot.key].map { SidebarDocDrag.display(hit, row: $0) } }
            probe = SidebarDropProbe(hit, displayY: point.y, baseY: y)
        } else if let hit = sidebar.bandHit(at: windowPoint, doc: doc, acceptance: acceptance) {
            list.bandDrop = nil
            target = hit.target
            if hit.target == nil { sidebar.hideDropLine() } else { sidebar.showDropLine(hit, in: sidebar.aboveRegion) }
            probe = SidebarDropProbe(hit, displayY: sidebar.aboveRegion.convert(windowPoint, from: nil).y, baseY: nil, indicator: "line")
        } else {
            clear(sidebar)
        }
    }

    /// Hides the gap and the line; the drop goes nowhere.
    func clear(_ sidebar: SidebarView) {
        sidebar.hideDropLine()
        sidebar.list.bandDrop = nil
        target = nil
        probe = nil
    }
}

extension SidebarDropProbe {
    /// The probe of a document hit: the slot, the zone and the drop look
    /// (`gap` or `into` in a list section, `line` in the band, `refused`).
    init(_ hit: SidebarDragGeometry.Hit?, displayY: CGFloat, baseY: CGFloat?, indicator: String? = nil) {
        let fraction = hit.map { hit in hit.slot.frame.height > 0 ? (((baseY ?? displayY) - hit.slot.frame.minY) / hit.slot.frame.height) : 0 }
        let look: String? = if let hit {
            hit.target == nil ? "refused" : hit.zone == .into && hit.slot.kind == .group ? "into" : (indicator ?? "gap")
        } else {
            nil
        }
        self.init(edge: "pointer", displayY: displayY, baseY: baseY, row: hit?.slot.key, fraction: fraction,
                  target: hit?.target.map { String(describing: $0) }, indicator: look, refusal: hit?.refusal)
    }
}
