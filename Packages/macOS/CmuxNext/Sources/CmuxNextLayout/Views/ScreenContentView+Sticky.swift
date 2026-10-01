import AppKit
import CmuxNextDesign
import QuartzCore

/// Sticky columns in the view (sticky-column.md, V1 to V4): sticky panes
/// and dividers sit at fixed frames above the strip, strip content shifts by
/// the strip origin minus the scroll, docked columns clip the strip, and
/// overlay columns float on a glass backdrop.
extension ScreenContentView {
    /// View x minus strip x at the presented scroll.
    var stripShift: CGFloat { geometry.viewShift(offset: scroll.value) }

    /// The part of the view where strip content shows (local coordinates).
    var uncoveredRect: CGRect {
        guard !geometry.sticky.isEmpty else { return bounds }
        return CGRect(x: geometry.uncoveredMinX, y: 0, width: max(0, geometry.uncoveredMaxX - geometry.uncoveredMinX), height: bounds.height)
    }

    /// What sticky columns hide of the strip (local coordinates): strip
    /// rings and highlights are clipped out of these.
    var coverRects: [CGRect] { geometry.sticky.map(\.cover) }

    /// True when the scroll moves this divider or column edge.
    func scrolls(_ kind: DividerHandleView.Kind) -> Bool {
        switch kind {
        case let .split(id): !geometry.fixedSplits.contains(id)
        case let .columnEdge(id): !geometry.sticky.contains { $0.column == id }
        }
    }

    /// A geometry rect for `pane` in local coordinates.
    func displayedRect(_ rect: CGRect, pane: PaneID) -> CGRect {
        geometry.scrolls(pane: pane) ? rect.offsetBy(dx: stripShift, dy: 0) : rect
    }

    /// True when `host` belongs to the scrolling strip.
    func isStripHost(_ host: PaneHostView) -> Bool { geometry.scrolls(pane: host.pane) }

    /// Docked columns clip strip panes that slide under them (V1): a layer
    /// mask keeps the part of the host inside the strip's uncovered range.
    /// Overlay columns cover them instead (z-order), so the glass rim has
    /// strip content to refract.
    func clipToStrip(_ host: PaneHostView, scrolls: Bool, uncovered: CGRect) {
        guard scrolls, geometry.sticky.contains(where: { $0.sticky.mode == .docked }) else { return host.setStripClip(nil) }
        let visible = host.frame.intersection(uncovered)
        if visible == host.frame { return host.setStripClip(nil) }
        host.setStripClip(visible.isNull ? .zero : visible.offsetBy(dx: -host.frame.minX, dy: -host.frame.minY))
    }

    /// Glass backdrops for overlay columns and the stacking order: strip
    /// hosts, strip dividers, backdrops, sticky hosts, sticky dividers,
    /// then the scrollbar.
    func reconcileSticky() {
        let overlays = geometry.sticky.filter { $0.sticky.mode == .overlay }
        let live = Set(overlays.map(\.column))
        for (column, view) in backdrops where !live.contains(column) {
            view.removeFromSuperview()
            backdrops[column] = nil
        }
        for entry in overlays {
            let view = backdrops[entry.column] ?? {
                let view = StickyBackdropView()
                addSubview(view)
                backdrops[entry.column] = view
                return view
            }()
            view.place(cover: entry.cover, column: entry.frame, paneCornerRadius: context.style.paneCornerRadius)
        }
        ensureStacking()
    }

    private func rank(_ view: NSView) -> Int {
        switch view {
        case let host as PaneHostView: geometry.scrolls(pane: host.pane) ? 0 : 3
        case let divider as DividerHandleView: scrolls(divider.kind) ? 1 : 4
        case is StickyBackdropView: 2
        case is StripScrollbarView: 5
        default: 0
        }
    }

    /// Reorders subviews only when the order is wrong. `sortSubviews`
    /// keeps every view in the window (no detach), so terminal surfaces and
    /// page windows are not torn down.
    private func ensureStacking() {
        let ranks = subviews.enumerated().map { rank($1) * 100_000 + $0 }
        guard ranks != ranks.sorted() else { return }
        let table = StackingTable(ranks: Dictionary(uniqueKeysWithValues: zip(subviews.map(ObjectIdentifier.init), ranks)))
        withExtendedLifetime(table) {
            sortSubviews({ a, b, context in
                guard let context else { return .orderedSame }
                let table = Unmanaged<StackingTable>.fromOpaque(context).takeUnretainedValue()
                let x = table.ranks[ObjectIdentifier(a)] ?? 0
                let y = table.ranks[ObjectIdentifier(b)] ?? 0
                return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
            }, context: Unmanaged.passUnretained(table).toOpaque())
        }
    }
}

/// Sort keys for `ensureStacking`, passed through `sortSubviews`' context.
private final class StackingTable: @unchecked Sendable {
    let ranks: [ObjectIdentifier: Int]
    init(ranks: [ObjectIdentifier: Int]) { self.ranks = ranks }
}
