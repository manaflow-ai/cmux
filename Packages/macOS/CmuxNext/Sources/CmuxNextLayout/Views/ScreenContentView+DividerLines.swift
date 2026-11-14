import AppKit
import CmuxNextDesign

extension ScreenContentView {
    /// Whether the handle of `kind` draws its line at rest: the style's line between panes, or, while
    /// panes are outlined (`borders`), a split's line beside a pane that draws no outline of its own.
    /// A column edge draws the same line where it parts two columns, or a dock from the strip: every pane
    /// edge shows the faint line the sidebar's edge shows (Leo, 2026-11-07). The strip's last column edge
    /// parts nothing and draws none.
    /// An agent chat and a New Tab page share the window's glass without a pane outline
    /// (`PaneContentChrome.paneFramesContent`), so two of them side by side under `panes` had nothing
    /// between them (https://github.com/manaflow-ai/cmux/issues/37425).
    func showsIdleLine(_ kind: DividerHandleView.Kind) -> Bool {
        let style = context.style
        if kind.usesRowSeparator { return style.showsRowSeparator }
        if case let .split(id) = kind, hiddenDividers.contains(id) { return false }
        if case let .columnEdge(column) = kind {
            // Where a split draws its line: the style's, or a theme's split divider color (`DividerHandleView`).
            guard let edge = baseGeometry.columnEdges.first(where: { $0.column == column }),
                  edge.dockEdge != nil || baseGeometry.columnOrder.last != column else { return false }
            return style.showsDividerLine || performWithTheme { Palette.surfaceOverride(.splitDivider) != nil }
        }
        if style.showsDividerLine { return true }
        guard style.drawsLines, style.showsPaneBorder, case let .split(id) = kind,
              let divider = baseGeometry.dividers.first(where: { $0.id == id }) else { return false }
        // Only the split's own panes count: they lie in the rect it divides (its container), which a flush
        // neighbouring column or row, or a scroll area's overflow, does not. Of those, the ones beside the line
        // reach into its hit area, centered on their gap; a point more across the line catches panes that only
        // touch it (a drag width as thin as the line). Docked splits and panes are in view coordinates, the
        // strip's in content coordinates: only one space is compared.
        let docked = baseGeometry.fixedSplits.contains(id)
        let container = divider.container.insetBy(dx: -0.5, dy: -0.5)
        let area = divider.axis == .horizontal ? divider.hitFrame.insetBy(dx: -1, dy: 0) : divider.hitFrame.insetBy(dx: 0, dy: -1)
        return baseGeometry.panes.contains { pane, frame in
            baseGeometry.fixedPanes.contains(pane) == docked && container.contains(frame) && frame.intersects(area)
                && context.hosts[pane]?.framesContent == false
        }
    }

    /// Hide Divider or Show Divider changed which of this screen's splits draw no line: their handles
    /// (``DividerHandleView/isLineHidden``) and the lines the overlay reports follow at once.
    func hiddenDividersDidChange(from old: Set<SplitID>) {
        guard hiddenDividers != old else { return }
        for split in old.symmetricDifference(hiddenDividers) {
            guard let view = dividerViews[.split(split)] else { continue }
            view.isLineHidden = hiddenDividers.contains(split)
        }
        paneFramingDidChange()
        context.overlayNeedsSync()
    }

    /// A pane's content started or stopped drawing its own outline: each handle reads its line at
    /// rest again, and the overlay reports the lines it now draws (the occlusion holes of pages).
    func paneFramingDidChange() {
        var changed = false
        for (kind, view) in dividerViews {
            let shows = showsIdleLine(kind)
            if view.showsIdleLine != shows { view.showsIdleLine = shows; changed = true }
        }
        if changed { context.overlayNeedsSync() }
    }
}
