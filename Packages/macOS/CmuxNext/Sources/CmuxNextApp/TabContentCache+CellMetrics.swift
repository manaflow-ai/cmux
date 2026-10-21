import CoreGraphics
import CmuxNextTerminal

extension TabContentCache {
    /// Ghostty's cell size in backing pixels at the configured font size, from
    /// any live terminal in a window at `scale` (cells differ per scale), for a
    /// new terminal's grid (``NewTerminalGrid``). Nil when none is.
    func configuredCellPixelSize(scale: CGFloat) -> CGSize? {
        for entry in terminals.values {
            let session = entry.session
            guard session.surfaceView.window?.backingScaleFactor == scale,
                  let cell = session.configuredCellPixelSize else { continue }
            return cell
        }
        return nil
    }
}
