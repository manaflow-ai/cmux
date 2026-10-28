import AppKit
import Foundation
import CmuxNextCopyMode
import CmuxNextWakeups
import GhosttyNextKit

/// A terminal session's echo predictions (`terminal.predictiveEcho`). It rides on the
/// session's ``TerminalInputSink``, so every surface the session swaps in shares it; it works on the
/// surface that took the last key.
///
/// - The session's delegate says at each key whether predictions are on
///   (``TerminalSessionDelegate/terminalSessionPredictiveEcho(_:)``). Off, there is no
///   ``PredictiveEchoDisplay`` and no engine, and each hook returns at once.
/// - Ghostty's `io_write_cb` on the main thread reports each write (``written(_:by:)``): inside the
///   surface's keyDown the bytes belong to that key; any other write (a paste, a report, the CLI's
///   text) drops the predictions. The callback may run with Ghostty's terminal lock held, so nothing
///   here reads the grid inside it.
/// - The view's `noteKeyTaken()` ends the key (``keyTaken(by:)``): its bytes go to the display, which
///   reads the grid and shows the prediction in the key's frame.
/// - It draws on a ``PredictiveEchoOverlay`` over the surface and ticks the display once per frame of
///   the surface's window while predictions wait for their echo.
final class PredictiveEchoSlot {
    /// The display for ``view``; nil while off and before the first key after it turned on.
    private(set) var display: PredictiveEchoDisplay?
    private(set) weak var view: TerminalSurfaceView?
    /// What the key being dispatched wrote so far.
    private var keyBytes: [UInt8] = []
    private var overlay: PredictiveEchoOverlay?
    private var frames: FrameClient?
    /// Ghostty's terminal font, for the cell size it was read at.
    private var cachedFont: (cell: CGSize, font: CTFont)?

    nonisolated init() {}

    /// Ghostty wrote `bytes` to the terminal on the main thread, inside `io_write_cb`.
    func written(_ bytes: Data, by view: TerminalSurfaceView) {
        guard let display, view === self.view else { return }
        if view.keyTextAccumulator != nil {
            keyBytes.append(contentsOf: bytes)
        } else {
            display.otherInput()
        }
    }

    /// `view` took a key (or its input method did): what the key wrote goes to the display.
    // perf-hot: 0.05ms terminal-key
    func keyTaken(by view: TerminalSurfaceView) {
        defer { keyBytes.removeAll(keepingCapacity: true) }
        guard let session = view.session, let mode = session.delegate?.terminalSessionPredictiveEcho(session) else {
            return tearDown()
        }
        guard let display, self.view === view, display.config.mode == mode else {
            // Turned on, changed, or another surface: a new display starts from an unconfirmed epoch.
            // This key's bytes were not collected (there was no display): it is not predicted.
            tearDown()
            self.view = view
            let remote = session.delegate?.terminalSessionIsRemote(session) ?? false
            display = PredictiveEchoDisplay(config: TerminalPredictiveEcho(mode: mode, isRemoteSession: remote), host: self)
            return
        }
        display.keySent(keyBytes)
    }

    /// Drops the display, its engine and its overlay.
    private func tearDown() {
        guard display != nil || overlay != nil || frames != nil else { return }
        frames?.deactivate()
        frames = nil
        overlay?.removeFromSuperview()
        overlay = nil
        display = nil
        view = nil
    }

    /// The terminal's font, its colors and its cell geometry in the view now.
    private func style(of view: TerminalSurfaceView, surface: ghostty_surface_t) -> PredictiveEchoOverlay.Style? {
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        guard let metrics = unsafe GhosttyTextRead.gridMetrics(surface),
              let cells = CopyModeCursorFrame(cellWidth: metrics.cell_width, cellHeight: metrics.cell_height,
                                              paddingLeft: metrics.padding_left, paddingTop: metrics.padding_top,
                                              viewHeight: view.bounds.height),
              let font = unsafe terminalFont(of: surface, cell: CGSize(width: metrics.cell_width, height: metrics.cell_height)),
              let theme = view.session?.theme?.colors ?? GhosttyRuntime.shared.themeColors,
              let colors = PredictiveEchoOverlay.colors(of: theme, backgroundOverride: view.session?.model.backgroundOverride)
        else { return nil }
        return PredictiveEchoOverlay.Style(font: font, foreground: colors.foreground, background: colors.background,
                                           cursor: colors.cursor, cells: cells)
    }

    /// Ghostty's primary face at the configured size (`ghostty_surface_quicklook_font`, +1), read again
    /// when the cell size changes (a font size change).
    private func terminalFont(of surface: ghostty_surface_t, cell: CGSize) -> CTFont? {
        if let cachedFont, cachedFont.cell == cell { return cachedFont.font }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        guard let read = unsafe GhosttyTextRead.quickLookFont(surface) else { return nil }
        cachedFont = (cell, read)
        return read
    }

    /// One read of `text` (UTF-8) from `columns` of viewport row `row`; nil when Ghostty could not read it.
    private static func text(_ surface: ghostty_surface_t, row: Int, columns: ClosedRange<Int>) -> [UInt8]? {
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                      x: UInt32(columns.lowerBound), y: UInt32(row)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                          x: UInt32(columns.upperBound), y: UInt32(row)),
            rectangle: false
        )
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        return unsafe GhosttyTextRead(surface, selection: selection)?.bytes
    }
}

extension PredictiveEchoSlot: PredictiveEchoHost {
    func readPredictionGrid(row: Int?, leftmost: Int?, readsBefore: Bool) -> PredictionRow? {
        guard let surface = view?.surface else { return nil }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        guard let metrics = unsafe GhosttyTextRead.gridMetrics(surface), metrics.cursor_in_viewport, metrics.columns > 0 else { return nil }
        let (columns, cursorRow, cursorColumn) = (Int(metrics.columns), Int(metrics.cursor_row), Int(metrics.cursor_column))
        let row = row ?? cursorRow
        guard row >= 0, row < Int(metrics.rows) else { return nil }
        let start = min(max(min(cursorColumn, leftmost ?? cursorColumn), 0), columns)
        // The engine predicts nothing on the alternate screen: its cells are not read.
        let alternate = metrics.alternate_screen
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        let text: [UInt8]? = unsafe alternate || start >= columns ? [] : Self.text(surface, row: row, columns: start...(columns - 1))
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        let before: [UInt8]? = unsafe readsBefore && !alternate && start > 0 ? Self.text(surface, row: row, columns: (start - 1)...(start - 1)) : nil
        return PredictionRow(cursorRow: cursorRow, cursorColumn: cursorColumn, columns: columns, isAlternateScreen: alternate,
                             row: row, start: start, text: text, beforeText: before)
    }

    var presentedFrameID: ObjectIdentifier? {
        view?.presentedFrame.map { ObjectIdentifier($0) }
    }

    var isSecureInput: Bool {
        view?.secureInput.isEnabled ?? false
    }

    var isComposing: Bool {
        view?.hasMarkedText() ?? false
    }

    /// The session's theme opacity, else the config's (with cmux.json's `appearance.backgroundOpacity`),
    /// as ``style(of:surface:)`` reads the colors.
    var isTranslucent: Bool {
        guard let view else { return false }
        return (view.session?.theme?.colors?.backgroundOpacity ?? GhosttyRuntime.shared.backgroundOpacity) < 1
    }

    /// The view's size and the cell size Ghostty last reported (`publish(size:)`): no call into Ghostty,
    /// so it is read on every frame and inside the write callback.
    var predictionGeometry: PredictiveEchoGeometry? {
        guard let view, let model = view.session?.model else { return nil }
        return PredictiveEchoGeometry(viewSize: view.bounds.size, cellSize: model.cellPixelSize)
    }

    func predictionsNeedFrames() {
        if frames == nil {
            // frame-client: the typed-ahead cells until the echo comes (an AppKit overlay, on main); key to frame
            frames = FrameClient(owner: "Terminal.predictiveEcho", isAnimation: false, rate: .motion, scheduler: { [weak self] in
                guard let view = self?.view else { return .app }
                return FrameScheduler.forView(view)
            }, onFrame: { [weak self] _ in
                self?.display?.frame() ?? false
            })
        }
        frames?.activate()
    }

    func showPredictions(_ cells: [PredictiveEcho.Cell], cursor: PredictiveEcho.Position?) {
        guard !cells.isEmpty || cursor != nil else {
            overlay?.show([], cursor: nil, style: nil)
            return
        }
        guard let view, let surface = view.surface else { return }
        let overlay = self.overlay ?? PredictiveEchoOverlay(frame: .zero)
        if overlay.superview !== view { view.addSubview(overlay) }
        self.overlay = overlay
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        overlay.show(cells, cursor: cursor, style: unsafe style(of: view, surface: surface))
    }
}
