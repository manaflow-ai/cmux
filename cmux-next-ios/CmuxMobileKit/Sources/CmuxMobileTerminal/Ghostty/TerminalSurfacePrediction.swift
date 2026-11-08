#if os(iOS)
import CmuxMobileDesign
import CmuxMobileLinkFFI
import GhosttyNextKit
import QuartzCore
import UIKit

/// Predictive local echo for one surface: a typed key shows at once,
/// underlined until the remote echoes it, instead of a round trip later.
///
/// The decisions are the shared Rust engine's (`cmux-terminal-prediction`, the
/// one the Mac app asks over cmux-app-ffi, here through CmuxMobileLinkFFI):
/// which glyphs to draw, when an echo confirms them, when a mismatch takes them
/// back, and when not to predict at all (a fast link, a password prompt, a
/// full-screen program, too many recent withdrawals). This class only feeds it
/// the surface's input, output and presented frames, and draws its answer over
/// the cursor row. Nothing here writes to the terminal grid, so a wrong guess
/// is withdrawn by hiding a glyph and the screen stays what the remote said.
///
/// Every terminal on the phone runs its shell on another machine, so each
/// surface is remote; the engine waits for a measured echo slower than its
/// threshold before it draws anything.
@MainActor
final class TerminalSurfacePrediction {
    let engine: PredictionEngineRef
    private let overlay = TerminalPredictionOverlayView()
    private weak var view: TerminalSurfaceView?
    private var expiry: Timer?
    private var enabled: Bool

    init(view: TerminalSurfaceView, alternateScreen: Bool) {
        enabled = CmuxMobilePreferences.predictiveEcho()
        engine = PredictionEngineRef(TerminalPrediction(enabled: enabled, remote: true))
        engine.prediction.seedAlternateScreen(active: alternateScreen)
        self.view = view
        overlay.isUserInteractionEnabled = false
        overlay.isOpaque = false
        overlay.isHidden = true
        // Above Ghostty's layer, which stays the view's first sublayer
        // (presents are observed there).
        view.addSubview(overlay)
    }

    isolated deinit {
        expiry?.invalidate()
    }

    nonisolated static func now() -> UInt64 {
        UInt64(max(0, CACurrentMediaTime()) * 1_000_000)
    }

    /// One write Ghostty encoded for the remote (`io_write_cb`), before it goes out.
    func sent(_ bytes: Data) {
        if engine.prediction.sent(bytes: bytes, nowUs: Self.now()) || !overlay.isHidden { refresh() }
    }

    /// Output was parsed (`TerminalSurfaceView.feed`); `changed` is the
    /// engine's answer for it on the output queue.
    func parsed(changed: Bool) {
        if changed || !overlay.isHidden { refresh() }
    }

    /// A frame reached the screen: held confirmations retire.
    func presented() {
        if engine.prediction.presentedFrame(nowUs: Self.now()) || !overlay.isHidden { refresh() }
    }

    /// The grid or the font changed under the glyphs: start over.
    func gridChanged() {
        _ = engine.prediction.missedOutput(nowUs: Self.now())
        refresh()
    }

    /// Settings → Terminal → Predictive echo.
    func applySetting() {
        let on = CmuxMobilePreferences.predictiveEcho()
        guard on != enabled else { return }
        enabled = on
        _ = engine.prediction.set(enabled: on, remote: true)
        refresh()
    }

    /// Draws what the engine says now, and arms the one timer for when that
    /// changes on its own (a glyph aging out). Nothing drawn, no timer.
    func refresh() {
        expiry?.invalidate()
        expiry = nil
        // Output took away blanks the frame on screen still shows: keep the
        // overlay as it is until the next presented frame.
        if engine.prediction.holdsLayout() { return }
        let now = Self.now()
        guard let view, let cursor = view.predictionCursor(),
              let layout = engine.prediction.layout(nowUs: now, cursorColumn: Int32(cursor.column), columns: Int32(cursor.columns))
        else {
            overlay.hide()
            return
        }
        overlay.show(layout, cursorCell: cursor.cell, fontSize: CGFloat(CmuxMobilePreferences.terminalFontSize()))
        guard let due = engine.prediction.nextExpiryUs() else { return }
        let delay = Double(due > now ? due - now : 0) / 1_000_000
        expiry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

/// The engine handle for the output queue. Safe to share: the Rust engine
/// sits behind a mutex held only for each call (cmux-mobile-link-ffi's
/// `terminal_prediction.rs`), and the handle itself is never reassigned.
struct PredictionEngineRef: @unchecked Sendable {
    let prediction: TerminalPrediction
    init(_ prediction: TerminalPrediction) { self.prediction = prediction }
}

/// The cursor row's predicted glyphs, drawn over Ghostty's cells: each cell
/// on the run gets the terminal's background, then its glyph (underlined while
/// speculative, plain while a confirmation waits for its frame, nothing for a
/// deleted one), and the caret where typing continues.
final class TerminalPredictionOverlayView: UIView {
    private var layout: PredictionLayout?
    private var fontSize: CGFloat = 0
    private var cellWidth: CGFloat = 0

    private static let foreground = UIColor(red: 0xE6 / 255, green: 0xE6 / 255, blue: 0xE6 / 255, alpha: 1)

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        layout = nil
    }

    func show(_ layout: PredictionLayout, cursorCell: CGRect, fontSize: CGFloat) {
        let frame = CGRect(x: cursorCell.minX + CGFloat(layout.leadingOffset) * cursorCell.width,
                           y: cursorCell.minY,
                           width: CGFloat(layout.cellCount) * cursorCell.width,
                           height: cursorCell.height)
        let same = !isHidden && self.layout == layout && self.frame == frame && self.fontSize == fontSize
        guard !same else { return }
        self.layout = layout
        self.fontSize = fontSize
        cellWidth = cursorCell.width
        self.frame = frame
        isHidden = false
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let layout, let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(CmuxMobileGhosttyApp.background.cgColor)
        context.fill(bounds)
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let baselineInset = (bounds.height - font.lineHeight) / 2
        for glyph in layout.glyphs {
            let cell = CGRect(x: CGFloat(glyph.offset - layout.leadingOffset) * cellWidth, y: 0, width: cellWidth, height: bounds.height)
            guard glyph.standing != 2 else { continue }
            let text = String(UnicodeScalar(glyph.character))
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.foreground]
            if glyph.standing == 0 { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            (text as NSString).draw(at: CGPoint(x: cell.minX, y: baselineInset), withAttributes: attributes)
        }
        if let caret = layout.caretOffset {
            let cell = CGRect(x: CGFloat(caret - layout.leadingOffset) * cellWidth, y: 0, width: cellWidth, height: bounds.height)
            context.setFillColor(Self.foreground.cgColor)
            context.fill(cell)
        }
    }
}

extension TerminalSurfaceView {
    /// The live cursor's cell (this view's points), its column and the grid's
    /// width, or nil when the cursor is outside the viewport.
    func predictionCursor() -> (cell: CGRect, column: Int, columns: Int)? {
        guard let surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cursor_in_viewport, metrics.cell_height > 0 else { return nil }
        let cell = CGRect(x: metrics.padding_left + Double(metrics.cursor_column) * metrics.cell_width,
                          y: metrics.padding_top + Double(metrics.cursor_row) * metrics.cell_height,
                          width: metrics.cell_width,
                          height: metrics.cell_height)
        return (cell, Int(metrics.cursor_column), grid.columns)
    }

    /// Whether a full-screen program owns the screen now (the engine's seed).
    var showsAlternateScreen: Bool {
        guard let surface else { return false }
        var metrics = ghostty_surface_grid_metrics_s()
        return ghostty_surface_grid_metrics(surface, &metrics) && metrics.alternate_screen
    }
}
#endif
