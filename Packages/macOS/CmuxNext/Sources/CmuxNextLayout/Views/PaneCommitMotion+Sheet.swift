import AppKit

/// The window's colour under a pane that moves.
///
/// A pane's tab row has no ground of its own, and neither has the padding around its content: at rest the window's
/// sheet shows there. A pane that a move keeps under the others (a pane that a close took out, a pane that a zoom
/// covers, the panes that an unzoom's pane closes over) would show there too, under the pane that goes over it. In a
/// window whose sheet is one plain colour the pane that moves has that colour on its host's layer, under its own
/// content and on its whole cell: it shows what it shows at rest, and nothing of a pane under it. The colour is a
/// property of a layer that the move already has: no layer more, no mask, and no pass of its own in a frame.
///
/// A window that shows what is behind it has no such colour, and a pane of a docked column has its dock's ground
/// under it, not the window's: those panes get none.
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

    /// Each tiled pane of `changes` shows the window's colour under its content from this pass to the motion's end
    /// (``hideSheets()``). A pane that an act before gave the colour keeps it, also when a later act takes that pane
    /// out: it then stays over the panes that it went over. Each pass reads the colour again, so a pane has the
    /// colour that the window has at the last act. With no such colour now, no pane shows one.
    func showSheet(under changes: [Change], on screen: ScreenContentView) {
        guard let color = Self.sheet(under: screen) else { return hideSheets() }
        for change in changes {
            let host = change.host
            guard let layer = host.layer, !host.isDocked, screen.baseGeometry.floatingCards[host.pane] == nil,
                  !sheets.contains(where: { $0.host === host }) else { continue }
            sheets.append((host: host, color: layer.backgroundColor))
        }
        for sheet in sheets { sheet.host.layer?.backgroundColor = color }
    }

    /// Each pane host's layer gets back the colour that it had before the motion.
    func hideSheets() {
        for sheet in sheets { sheet.host.layer?.backgroundColor = sheet.color }
        sheets = []
    }
}
