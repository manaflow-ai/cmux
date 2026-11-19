import AppKit

/// The ground under a pane that moves.
///
/// A pane's tab row has no ground of its own, and neither has the padding around its content: at rest what is under
/// the pane shows there. A pane that a move keeps under the others (a pane that a close took out, a pane that a zoom
/// covers, the panes that an unzoom's pane closes over) would show there too, under the pane that goes over it. So a
/// pane that moves has the colour of what is under it at rest on its host's layer, under its own content and on its
/// whole cell: it shows what it shows at rest, and nothing of a pane under it. The colour is a property of a layer
/// that the move already has: no layer more, no mask, and no pass of its own in a frame.
///
/// What is under a pane at rest (``ground(under:on:sheet:)``): the window's sheet under a strip pane and under a
/// pane of a column at the screen's edge in the `docked` mode (that mode has no view under its panes; a colour that
/// the user set for the docks is on the pane's own clip, over this ground); the opaque ground of the column's
/// backdrop in the `overlay` mode; and the card of a floating pane. A window that shows what is behind it has no
/// plain sheet, and a card with a see-through look or a tint is no plain colour: those panes get none.
extension PaneCommitMotion {
    /// The colour of the window's sheet under the panes of `screen`: the window's own background colour, when the
    /// window is opaque and that colour has no alpha. Nil: the window shows what is behind it.
    static func sheet(under screen: ScreenContentView) -> CGColor? {
        guard let window = screen.window, window.isOpaque else { return nil }
        var read: CGColor?
        screen.effectiveAppearance.performAsCurrentDrawingAppearance { read = window.backgroundColor?.cgColor }
        guard let color = read, color.alpha >= 1 else { return nil }
        return color
    }

    /// What holds `host` on `screen` over the window's sheet, and the plain colour that it shows under the pane: the
    /// card of a floating pane (nil with a see-through look or a tint), or the opaque ground of the backdrop of a
    /// column in the `overlay` mode. `holds` false: the window's sheet is under the pane (a strip pane, a pane of a
    /// column in the `docked` mode).
    static func holder(of host: PaneHostView, on screen: ScreenContentView) -> (holds: Bool, color: CGColor?) {
        let geometry = screen.baseGeometry
        if geometry.floatingCards[host.pane] != nil { return (true, screen.floatState.cards[host.pane]?.solidGround) }
        if let dock = geometry.dockFrame(containing: host.pane), dock.dock.mode == .overlay,
           let fill = screen.backdrops[dock.column]?.ground, fill.alpha >= 1 {
            return (true, fill)
        }
        return (false, nil)
    }

    /// The colour of what is under `host` at rest on `screen`, whose window's sheet is `sheet`. Nil: no plain colour.
    static func ground(under host: PaneHostView, on screen: ScreenContentView, sheet: CGColor?) -> CGColor? {
        let holder = Self.holder(of: host, on: screen)
        return holder.holds ? holder.color : sheet
    }

    /// Each pane of `changes` shows its ground under its content from this pass to the motion's end
    /// (``hideSheets()``). A pane that an act before gave a colour keeps one, also when a later act takes that pane
    /// out: it then stays over the panes that it went over. Each pass reads each pane's ground again, so a pane has
    /// the colour that is under it at the last act, and a pane with no plain colour under it now gets its own back.
    func showSheet(under changes: [Change], on screen: ScreenContentView) {
        let sheet = Self.sheet(under: screen)
        for change in changes where change.host.layer != nil && !sheets.contains(where: { $0.host === change.host }) {
            sheets.append((host: change.host, color: change.host.layer?.backgroundColor))
        }
        sheets.removeAll { entry in
            guard let layer = entry.host.layer else { return true }
            let ground = Self.ground(under: entry.host, on: screen, sheet: sheet)
            let color = ground ?? entry.color
            if layer.backgroundColor != color { layer.backgroundColor = color }
            return ground == nil
        }
    }

    /// Each pane host's layer gets back the colour that it had before the motion.
    func hideSheets() {
        for sheet in sheets { sheet.host.layer?.backgroundColor = sheet.color }
        sheets = []
    }
}
