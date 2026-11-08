import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import GhosttyNextKit
import ObjectiveC
import QuartzCore

/// Predictive local echo for one terminal whose shell runs on another machine (``TerminalIO/predictsEcho``): a typed
/// key shows at once, underlined until the remote echoes it, instead of a round trip later.
///
/// The engine (``TerminalEchoPrediction``, the shared Rust engine) decides everything; this class draws its answer in
/// a small overlay over the cursor row of the live surface and keeps the one timer for when that answer changes on its
/// own. Nothing here writes to the terminal grid, so a wrong guess is withdrawn by hiding a glyph and the screen stays
/// what the remote said. Input reaches the engine on Ghostty's IO thread (`ghosttyIOWrite`), output on the output lane
/// after Ghostty parsed it (``TerminalOutputLane``), frames from the surface layer (``TypingFrameProbe``); each asks
/// for one ``refresh()`` only when its answer changes what is drawn.
@MainActor
final class TerminalEchoPredictor {
    let engine: TerminalEchoPrediction
    private let overlay = TerminalPredictionOverlayView()
    private weak var surfaceView: TerminalSurfaceView?
    /// The one timer, for the engine's next deadline. Stop condition: none while nothing is drawn, and
    /// ``close()`` cancels it.
    private let expiry = DemandTimer(owner: "TerminalEchoPredictor.expiry")
    private var isClosed = false
    /// The overlay's colors: the terminal's theme, else the app config's.
    var colors: () -> GhosttyThemeColors? = { GhosttyRuntime.shared.themeColors }

    init(engine: TerminalEchoPrediction) {
        self.engine = engine
        engine.onRedraw { [weak self] in self?.refresh() }
    }

    /// What the overlay draws now, nil while hidden (tests).
    var drawnLayout: TerminalEchoPrediction.Layout? { overlay.isHidden ? nil : overlay.layout }
    /// Called with the new layout each time what the overlay draws changes (tests and benches).
    var onDrawChange: ((TerminalEchoPrediction.Layout?) -> Void)?

    /// Draws over `view`, the session's live surface (made or swapped in). A fresh surface shows no full-screen
    /// program until its content says so; a replay into it seeds the engine again once parsed.
    func attach(to view: TerminalSurfaceView) {
        guard surfaceView !== view else { return }
        surfaceView = view
        overlay.removeFromSuperview()
        overlay.hide()
        view.addSubview(overlay)
        if let layer = view.layer { TypingFrameProbe.watchPresents(of: layer, for: engine) }
        engine.seedAlternateScreen(view.isAlternateScreen)
        refresh()
    }

    /// The grid changed under the glyphs (a new PTY grid): start over.
    func gridChanged() {
        engine.missedOutput(alternateScreen: surfaceView?.isAlternateScreen)
    }

    func close() {
        isClosed = true
        engine.onRedraw(nil)
        expiry.cancel()
        overlay.hide()
        engine.setDrawing(false)
        overlay.removeFromSuperview()
    }

    /// Draws what the engine says now and arms the one timer for when that changes on its own (a glyph aging out).
    func refresh() { // perf-hot: 0.1ms terminal-key (each key and echo of a predicting terminal)
        expiry.cancel()
        guard !isClosed else { return }
        // Output took away blanks the frame on screen still shows: the overlay stays until the next presented
        // frame, still waking for the engine's own deadline if none comes (the tick lets a hold that outlived it go).
        engine.tick()
        if engine.holdsLayout {
            armExpiry()
            return
        }
        guard let view = surfaceView, let cursor = view.predictionCursor(),
              let layout = engine.layout(cursorColumn: cursor.column, columns: cursor.columns) else {
            let was = drawnLayout
            overlay.hide()
            engine.setDrawing(false)
            if was != nil { onDrawChange?(nil) }
            return
        }
        let was = drawnLayout
        let colors = colors()
        overlay.show(layout, cursorCell: cursor.cell, foreground: colors.map { NSColor($0.foreground) } ?? .textColor,
                     background: colors.map { NSColor($0.background) } ?? .textBackgroundColor)
        engine.setDrawing(true)
        if was != layout { onDrawChange?(layout) }
        armExpiry()
    }

    private func armExpiry() {
        guard let due = engine.nextExpiry else { return }
        let now = TerminalEchoPrediction.now()
        expiry.schedule(after: .microseconds(Int64(clamping: due > now ? due - now : 0))) { @MainActor [weak self] in
            self?.refresh()
        }
    }
}

/// The cursor row's predicted glyphs, drawn over Ghostty's cells: each cell of the run gets the terminal's background,
/// then its glyph (underlined while speculative, plain while a confirmation waits for its frame, nothing for a deleted
/// one), and the caret where typing continues. A layer-backed view of one row, redrawn only when the layout changes.
final class TerminalPredictionOverlayView: NSView {
    private(set) var layout: TerminalEchoPrediction.Layout?
    private var cellWidth: CGFloat = 0
    private var foreground: NSColor = .textColor
    private var background: NSColor = .textBackgroundColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Clicks and drags go to the terminal under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        layout = nil
    }

    /// `cursorCell`: the live cursor's cell in the surface view's coordinates.
    func show(_ layout: TerminalEchoPrediction.Layout, cursorCell: CGRect, foreground: NSColor, background: NSColor) {
        let frame = CGRect(x: cursorCell.minX + CGFloat(layout.leadingOffset) * cursorCell.width, y: cursorCell.minY,
                           width: CGFloat(layout.cellCount) * cursorCell.width, height: cursorCell.height)
        let same = !isHidden && self.layout == layout && self.frame == frame && self.foreground == foreground
            && self.background == background
        guard !same else { return }
        self.layout = layout
        self.foreground = foreground
        self.background = background
        cellWidth = cursorCell.width
        self.frame = frame
        isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, cellWidth > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(background.cgColor)
        context.fill(bounds)
        let font = Self.font(cellWidth: cellWidth, cellHeight: bounds.height)
        let baseline = (bounds.height - (font.ascender - font.descender)) / 2
        for glyph in layout.glyphs where glyph.standing != .erased {
            let x = CGFloat(glyph.offset - layout.leadingOffset) * cellWidth
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
            if glyph.standing == .speculative { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            (String(UnicodeScalar(glyph.character)) as NSString).draw(at: CGPoint(x: x, y: baseline), withAttributes: attributes)
        }
        if let caret = layout.caretOffset {
            context.setFillColor(foreground.cgColor)
            context.fill(CGRect(x: CGFloat(caret - layout.leadingOffset) * cellWidth, y: 0, width: cellWidth, height: bounds.height))
        }
    }

    /// The system monospaced font sized so one character fills one cell (Ghostty's own font is not exposed;
    /// a glyph shows for one round trip, until the remote's echo replaces it).
    private static func font(cellWidth: CGFloat, cellHeight: CGFloat) -> NSFont {
        let size = min(cellWidth / advancePerPoint, cellHeight * 0.8)
        return NSFont.monospacedSystemFont(ofSize: max(1, size), weight: .regular)
    }

    /// The monospaced font's advance per point of size, measured once at the body size.
    private static let advancePerPoint: CGFloat = {
        let size = TypeScale.body
        let reference = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let advance = ("M" as NSString).size(withAttributes: [.font: reference]).width
        return advance > 0 && size > 0 ? advance / size : 0.6
    }()
}

extension NSColor {
    convenience init(_ rgb: GhosttyThemeColors.RGB) {
        self.init(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}

extension TerminalSurfaceView {
    /// The live cursor's cell (this view's coordinates), its column and the grid's width, or nil when the cursor is
    /// outside the viewport.
    func predictionCursor() -> (cell: CGRect, column: Int, columns: Int)? {
        guard let surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cursor_in_viewport, metrics.cell_height > 0,
              metrics.columns > 0 else { return nil }
        let top = metrics.padding_top + Double(metrics.cursor_row) * metrics.cell_height
        let cell = CGRect(x: metrics.padding_left + Double(metrics.cursor_column) * metrics.cell_width,
                          y: bounds.height - top - metrics.cell_height,
                          width: metrics.cell_width, height: metrics.cell_height)
        return (cell, Int(metrics.cursor_column), Int(metrics.columns))
    }
}
