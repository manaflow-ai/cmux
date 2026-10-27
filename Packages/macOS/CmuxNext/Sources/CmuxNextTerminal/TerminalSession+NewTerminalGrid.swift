public import CoreGraphics

// What a new terminal in this terminal's pane would fit.
extension TerminalSession {
    /// The grid a new terminal in this terminal's pane would fit: this view's
    /// fitted grid while it is in a window at the configured font size. Nil
    /// before its first layout, out of a window, or with its font zoomed (a
    /// new terminal starts at the configured size).
    public var gridForNewTerminal: TerminalGridSize? {
        guard surfaceView.window != nil, TerminalFontScale(surfaceView).current == nil else { return nil }
        return surfaceView.fittedGrid
    }

    /// Ghostty's cell size in backing pixels at the configured font size, for
    /// working out a new terminal's grid (``TerminalGridEstimate``). Nil while
    /// unknown or with this terminal's font zoomed.
    public var configuredCellPixelSize: CGSize? {
        let cell = model.cellPixelSize
        guard cell.width > 0, cell.height > 0, TerminalFontScale(surfaceView).current == nil else { return nil }
        return cell
    }
}
