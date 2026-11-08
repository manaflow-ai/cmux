#if os(iOS)
import CmuxMobileDesign
import CmuxMobileLinkFFI
import Foundation
import GhosttyNextKit
import UIKit

/// Predictive local echo: the characters the phone draws before the remote
/// echoes them (Settings → Terminal → Predictive echo, on by default).
///
/// Every phone terminal is remote, so every key waits a round trip of the
/// link. The engine (`TerminalPrediction`, the Mac's Rust engine over the
/// phone's FFI) sees each write Ghostty encodes and each output batch just
/// before Ghostty parses it, and answers which characters may be drawn. Only
/// inside a confirmed echo run (two keys echoed in a row) and only on a link
/// slower than 25 ms, so a password prompt and a LAN draw nothing.
///
/// This view draws them over the surface, on the cursor row, and never
/// writes them to the grid: a wrong guess is withdrawn by drawing less. It is
/// sized to the run, hidden when there is none, and takes no touches. Its one
/// expiry task runs only while something is in flight.
@MainActor
final class TerminalPredictionOverlay: UIView {
    /// Thread safe (a mutex inside): output reaches it on the output queue.
    nonisolated let prediction: TerminalPrediction
    private var run: PredictionRun?
    private var cellSize: CGSize = .zero
    private var font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var expiry: Task<Void, Never>?

    /// Ghostty's colours on the phone (`CmuxMobileGhosttyApp.loadProductConfig`).
    private static let foreground = UIColor(red: 0xE6 / 255, green: 0xE6 / 255, blue: 0xE6 / 255, alpha: 1)

    init(enabled: Bool) {
        prediction = TerminalPrediction(enabled: enabled)
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        contentMode = .redraw
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { expiry?.cancel() }

    /// Microseconds of the clock every call uses.
    nonisolated static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000 }

    /// Places and draws the run for the surface's cursor as it is now.
    func update(surface: ghostty_surface_t, fontSize: Int) {
        let now = Self.now()
        // Output removed cells the frame on screen still shows: stay put until it presents.
        if prediction.holdsLayout(), run != nil { return scheduleExpiry() }
        var metrics = ghostty_surface_grid_metrics_s()
        let columns = Int32(ghostty_surface_size(surface).columns)
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cursor_in_viewport, metrics.cell_width > 0,
              let next = prediction.run(nowUs: now, cursorColumn: Int32(metrics.cursor_column), columns: columns)
        else {
            show(nil)
            return scheduleExpiry()
        }
        let cell = CGSize(width: metrics.cell_width, height: metrics.cell_height)
        frame = CGRect(x: metrics.padding_left + (Double(metrics.cursor_column) + Double(next.leadingOffset)) * cell.width,
                       y: metrics.padding_top + Double(metrics.cursor_row) * cell.height,
                       width: Double(next.cellCount) * cell.width, height: cell.height)
        if cell != cellSize || Int(font.pointSize) != fontSize {
            cellSize = cell
            font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        }
        show(next)
        scheduleExpiry()
    }

    /// Nothing is drawn (the setting turned off, the surface went away).
    func clear() {
        expiry?.cancel()
        expiry = nil
        show(nil)
    }

    private func show(_ next: PredictionRun?) {
        guard next != run else { return }
        run = next
        isHidden = next == nil
        setNeedsDisplay()
    }

    /// One task, until the next glyph expires; none while nothing is in flight.
    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = nil
        guard let at = prediction.nextExpiryUs() else { return }
        let wait = at > Self.now() ? at - Self.now() : 0
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .microseconds(Int64(clamping: wait) + 1_000))
            guard !Task.isCancelled, let self else { return }
            self.expiry = nil
            if self.prediction.tick(nowUs: Self.now()) { self.onExpire?() }
        }
    }

    /// An expiry changed what is drawn: the surface lays the run out again.
    var onExpire: (() -> Void)?

    override func draw(_ rect: CGRect) {
        guard let run, cellSize.width > 0, let context = UIGraphicsGetCurrentContext() else { return }
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.foreground]
        // Underlined until the remote echoes it: the convention mosh set, and the
        // only cue that tells a guess from the truth.
        var underlined = plain
        underlined[.underlineStyle] = NSUnderlineStyle.single.rawValue
        for glyph in run.cells {
            let cell = CGRect(x: CGFloat(glyph.offset - run.leadingOffset) * cellSize.width, y: 0,
                              width: cellSize.width, height: cellSize.height)
            // Each cell paints its background first: Ghostty still draws its
            // cursor block under the first predicted cell, and a deleted
            // character's echo stays covered until the remote's erase lands.
            context.setFillColor(CmuxMobileGhosttyApp.background.cgColor)
            context.fill(cell)
            if glyph.standing == .erased { continue }
            let text = String(UnicodeScalar(glyph.character)) as NSString
            let attributes = glyph.standing == .speculative ? underlined : plain
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: cell.minX + max(0, (cell.width - size.width) / 2),
                                  y: cell.minY + max(0, (cell.height - size.height) / 2)),
                      withAttributes: attributes)
        }
        // A caret where typing continues, since Ghostty's own cursor still sits
        // under the first predicted cell.
        if let caret = run.caretOffset {
            context.setFillColor(Self.foreground.cgColor)
            context.fill(CGRect(x: CGFloat(caret - run.leadingOffset) * cellSize.width, y: 0,
                                width: max(1, cellSize.width / 6), height: cellSize.height))
        }
    }
}
#endif
