#if os(iOS)
import CmuxMobileDesign
import QuartzCore
import UIKit

/// Watches a full-screen app's frames while the finger scrolls it: from each wheel report until
/// ``watch`` after the last, every presented frame's rows are matched to the previous frame's
/// (``TerminalTUIRowMove``), so the screen knows when and how far the app moved its rows.
/// ``travel`` adds those moves up (the bench's measure of where the content was drawn).
@MainActor
final class TerminalTUISmoother {
    /// The surface, its row height (points), its pixels per point and the app's screen rows, or
    /// nil while the surface is not showing a full-screen app.
    var geometry: () -> (surface: TerminalSurfaceView, rowHeight: CGFloat, scale: CGFloat, rows: Int)? = { nil }

    /// Points the content moved since the app's screen came up (the rows it moved, as presented).
    private(set) var travel: CGFloat = 0
    /// The last presented frame's row hashes while watching.
    private var rows: [UInt64]?
    private var watchUntil: CFTimeInterval = 0
    /// Frames are watched this long after the last wheel report (the app's reply on a slow link).
    static let watch: CFTimeInterval = 0.8

    /// A wheel report went to the app: watch its frames, from the frame on screen now.
    func wheelSent() {
        watchUntil = CACurrentMediaTime() + Self.watch
        if rows == nil { rows = read()?.rows }
    }

    /// A frame was presented (the screen's present handler, in the transaction that shows it).
    func presented() {
        guard CACurrentMediaTime() < watchUntil, let frame = read() else {
            rows = nil
            return
        }
        defer { rows = frame.rows }
        guard let previous = rows,
              let move = TerminalTUIRowMove.between(previous: previous, current: frame.rows, rows: 0..<frame.screenRows) else { return }
        travel += CGFloat(move.rows) * frame.rowHeight
    }

    /// Where the content is drawn now (points, positive down): the bench's position.
    var contentY: CGFloat { travel }

    /// The app's screen went away (or the page did).
    func reset() {
        rows = nil
        watchUntil = 0
    }

    private func read() -> (rows: [UInt64], rowHeight: CGFloat, screenRows: Int)? {
        guard let geometry = geometry(), geometry.rowHeight > 0, geometry.rows > 0 else { return nil }
        let rowPixels = Int((geometry.rowHeight * geometry.scale).rounded())
        guard let rows = geometry.surface.presentedRowSignatures(rowHeight: rowPixels, band: 0..<geometry.rows) else { return nil }
        return (rows, geometry.rowHeight, geometry.rows)
    }
}
#endif
