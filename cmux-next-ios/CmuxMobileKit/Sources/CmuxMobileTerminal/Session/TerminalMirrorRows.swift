import CoreGraphics

/// The phone's mirror (Ghostty surface) height in rows.
///
/// The Mac's rows map onto the mirror's bottom rows by a fixed offset
/// (`TerminalRowShift`: offset = mirror rows - remote rows). Ghostty moves
/// the primary screen's rows when the mirror is resized, so a resize while
/// an inline TUI streams misplaces its positioned writes until the next
/// replay (verifier V2-1: the tab grid's zoom laid the page out at
/// 893-963 pt, and the mirror followed it from 151 to 157 rows). So the
/// rows come from the screen, which a zoom, a keyboard or a rotation does not
/// change: the longer screen side plus a margin above and below. A page taller
/// than the screen (a transient layout) only narrows the margins.
struct TerminalMirrorRows {
    static func rows(pageHeight: CGFloat, screenSize: CGSize, cellHeight: CGFloat, scale: CGFloat, marginRows: Int) -> Int {
        guard cellHeight > 0 else { return 0 }
        // The largest texture Metal allows (8192 px; a bigger surface's
        // frames are discarded by Ghostty's layer).
        let maxRows = Int(floor(8192 / (cellHeight * max(1, scale))))
        let screenRows = Int(ceil(max(screenSize.width, screenSize.height) / cellHeight))
        // A page taller than the screen still keeps half a margin on each side.
        let pageRows = Int(ceil(pageHeight / cellHeight)) + marginRows
        return min(max(screenRows + 2 * marginRows, pageRows), maxRows)
    }
}
