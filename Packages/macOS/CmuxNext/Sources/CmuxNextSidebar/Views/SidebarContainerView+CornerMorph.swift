public import AppKit
public import CmuxNextDesign

// Debug `sidebar.cornerMorph` (Leo 2026-11-05, "fake the morph"): the rects the window's chrome shade joins to
// the main pane's card. The sidebar draws nothing new; it only says where its titlebar row and its selected
// row are, and calls the window back when they move.
public extension SidebarContainerView {
    /// The shade and morph for the window's chrome shade now: `alpha` as given and nil while the variant is off,
    /// at the compact sidebar density (Lawrence's; it keeps the plain card), in the rail style, while the sidebar
    /// is hidden, or when `enabled` is false (a page presented, floating panes). Works on the curved card and on
    /// the default flat chrome, where the content area is the (square, flush) card. Keeps `reshape` to call, in the same turn, whenever
    /// the selected row, the scroll offset or the titlebar row moves, so the join never trails them by a frame.
    func cornerMorphShade(_ alpha: CGFloat, isDark: Bool, in view: NSView, enabled: Bool,
                          reshape: @escaping @MainActor () -> Void) -> (alpha: CGFloat, morph: CornerMorph?) {
        cornerMorphReshape = reshape
        let result = cornerMorphShape(alpha, isDark: isDark, in: view, enabled: enabled)
        // The tint parts the sidebar from the content while a morph is on; the full-height edge hairline would
        // cut straight through the joins, so it steps aside (`updateResizeLine`).
        if cornerMorphHidesLine != (result.morph != nil) {
            cornerMorphHidesLine = result.morph != nil
            if cornerMorphHidesLine { handle.lineMinY = .greatestFiniteMagnitude } else if !Metrics.mainPaneCurved { handle.lineMinY = 0 }
        }
        return result
    }

    private func cornerMorphShape(_ alpha: CGFloat, isDark: Bool, in view: NSView, enabled: Bool) -> (alpha: CGFloat, morph: CornerMorph?) {
        let variant = CornerMorphVariant.tunable.value
        guard enabled, variant != .off, SidebarDensityTokens.density != .compact, model.style != .rail,
              !model.isHidden, !isHiddenOrHasHiddenAncestor, window != nil else { return (alpha, nil) }
        var morph = CornerMorph(rowRadius: SidebarStyle.rowCornerRadius, fillet: SidebarStyle.rowCornerRadius)
        if variant.joinsHeader {
            // The titlebar row, from the window's edge gutter to the sidebar's far edge (`surface` widens it to
            // the card and clamps it to the card's top, so the band and the tabs share one top edge).
            let bar = sidebarView, gutter = Metrics.mainPaneGutter
            let row = view.convert(bar.convert(NSRect(x: 0, y: 0, width: bar.bounds.width, height: bar.titlebarHeight), to: nil), from: nil)
            let minX = side == .left ? view.bounds.minX + gutter : row.minX
            let maxX = side == .left ? row.maxX : view.bounds.maxX - gutter
            morph.header = NSRect(x: minX, y: row.minY, width: max(0, maxX - minX), height: row.height)
        }
        if variant.joinsSelectedRow { morph.row = selectedRowRect(in: view) }
        return morph.isEmpty ? (alpha, nil) : (variant.shade(alpha, isDark: isDark), morph)
    }

    /// The selected workspace row's pill in `view`'s coordinates; nil when it is not realized or not wholly
    /// shown in the list (a sliver would join as a thin spike).
    private func selectedRowRect(in view: NSView) -> NSRect? {
        let list = sidebarView.list
        guard let key = list.selectedRowKey, let row = list.rowViews[key], !row.isHidden, row.alphaValue > 0 else { return nil }
        let frame = row.convert(row.bounds, to: nil)
        let clipped = frame.intersection(list.convert(list.visibleRect, to: nil))
        guard !clipped.isNull, clipped.height >= frame.height - 0.5 else { return nil }
        return view.convert(frame, from: nil)
    }
}

extension SidebarContainerView {
    /// A morph anchor under `view` moved: the sidebar holding it reshapes the window's shade (only while a variant
    /// is on; the walk up is a few superviews).
    static func cornerMorphMoved(from view: NSView) {
        guard CornerMorphVariant.tunable.value != .off else { return }
        var next = view.superview
        while let current = next {
            if let container = current as? SidebarContainerView { container.cornerMorphReshape?(); return }
            next = current.superview
        }
    }
}
