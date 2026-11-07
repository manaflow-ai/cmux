import AppKit

extension ScreenContentView {
    /// Whether the handle of `kind` draws its line at rest: the style's line between panes, or, while
    /// panes are outlined (`borders`), a split's line beside a pane that draws no outline of its own.
    /// An agent chat and a New Tab page share the window's glass without a pane outline
    /// (`PaneContentChrome.paneFramesContent`), so two of them side by side under `panes` had nothing
    /// between them (https://github.com/manaflow-ai/cmux/issues/37425).
    func showsIdleLine(_ kind: DividerHandleView.Kind) -> Bool {
        let style = context.style
        if kind.usesRowSeparator { return style.showsRowSeparator }
        if style.showsDividerLine { return true }
        guard style.drawsLines, style.showsPaneBorder, case let .split(id) = kind,
              let divider = baseGeometry.dividers.first(where: { $0.id == id }) else { return false }
        // The panes on either side of the line reach into its hit area, which is centered on their gap.
        return baseGeometry.panes.contains { pane, frame in
            frame.intersects(divider.hitFrame) && context.hosts[pane]?.framesContent == false
        }
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
