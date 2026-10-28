import Foundation

/// What places the overlay's cells in the surface view: the view's size (rows count from its top, in a
/// view that is not flipped) and Ghostty's cell size (the font size). Another value while predictions
/// show means the cells moved under them.
struct PredictiveEchoGeometry: Equatable {
    var viewSize: CGSize
    var cellSize: CGSize
}

/// What ``PredictiveEchoDisplay`` reads from and draws on: the session's ``PredictiveEchoSlot`` over
/// its surface view, or a test's.
protocol PredictiveEchoHost: AnyObject {
    /// The grid now (``PredictionRow``): row `row` (nil: the cursor's) from the cursor's column or
    /// `leftmost`, whichever is further left, to the right margin, and the cell left of that when
    /// `readsBefore`. Nil while the cursor is outside the viewport or there is no grid.
    func readPredictionGrid(row: Int?, leftmost: Int?, readsBefore: Bool) -> PredictionRow?
    /// The frame the surface shows now; another value means Ghostty presented a new frame.
    var presentedFrameID: ObjectIdentifier? { get }
    /// Secure keyboard entry is on (a password prompt).
    var isSecureInput: Bool { get }
    /// An input method has marked text (Ghostty draws its preedit at the cursor).
    var isComposing: Bool { get }
    /// The terminal background is translucent (`background-opacity` below 1): a predicted cell's fill
    /// would show as a block, and a translucent fill could not hide the glyph under a predicted blank.
    var isTranslucent: Bool { get }
    /// Where the overlay's cells are now; nil while there is no surface.
    var predictionGeometry: PredictiveEchoGeometry? { get }
    /// Predictions wait for their echo: call ``PredictiveEchoDisplay/frame()`` once per display frame
    /// until it returns false.
    func predictionsNeedFrames()
    /// Draws `cells` (a glyph dim and underlined, a blank as background) and the predicted cursor
    /// over the grid; nothing when both are empty. Called inside Ghostty's write callback too (to
    /// hide only), so hiding never calls into Ghostty.
    func showPredictions(_ cells: [PredictiveEcho.Cell], cursor: PredictiveEcho.Position?)
}

/// Shows a terminal's echo predictions: it feeds ``PredictiveEcho`` the bytes each key
/// sent and the grid Ghostty draws, and puts the predicted cells on the host's overlay, a cmux layer
/// over the surface. Not Ghostty's preedit, which cannot show a backspace over a cell.
///
/// - A key turn: ``keySent(_:)`` with the bytes the key wrote, once Ghostty sent them. The
///   prediction shows in that key's frame.
/// - Any other write (a paste, a mouse or focus report, an input method's commit outside a key):
///   ``otherInput()`` drops every prediction and starts a new epoch, so nothing shows until an echo
///   confirms again. It reads no grid: it runs inside Ghostty's write callback.
/// - Each display frame while predictions wait: when Ghostty presented a new frame or a prediction's
///   deadline came, the grid is read once and the echo is matched (``frame()``).
/// - Nothing is predicted, and nothing shows, while an input method composes, secure input is on or
///   the background is translucent.
/// - A resize or a font size change while predictions show (``PredictiveEchoGeometry``) drops them:
///   their cells are no longer where the overlay drew them, and the grid may have reflowed.
///
/// Every rollback is exact: the overlay draws nothing and the real grid shows through. Nothing here
/// writes to the terminal or the daemon.
final class PredictiveEchoDisplay {
    let config: TerminalPredictiveEcho
    private(set) var engine: PredictiveEcho
    private weak var host: (any PredictiveEchoHost)?
    private let now: () -> ContinuousClock.Instant
    private var lastFrame: ObjectIdentifier?
    private var shown: (cells: [PredictiveEcho.Cell], cursor: PredictiveEcho.Position?) = ([], nil)
    /// The geometry ``shown`` was drawn at.
    private var shownGeometry: PredictiveEchoGeometry?

    init(config: TerminalPredictiveEcho, host: any PredictiveEchoHost,
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.config = config
        self.host = host
        self.now = now
        engine = PredictiveEcho(mode: config.engineMode)
        lastFrame = host.presentedFrameID
    }

    /// A key went to the terminal and wrote `bytes`. A key that wrote nothing (a modifier, a Ghostty
    /// binding) sent the host nothing to echo: the predictions stay as they are.
    // perf-hot: 0.05ms terminal-key
    func keySent(_ bytes: [UInt8]) {
        guard let host else { return }
        guard canShow(host) else { return rollback() }
        guard !bytes.isEmpty else { return }
        guard let screen = host.readPredictionGrid(row: engine.pending.first?.row, leftmost: leftmostColumn,
                                                   readsBefore: bytes.contains(PredictiveEcho.delete)) else {
            return rollback()
        }
        engine.update(conditions(host))
        engine.typed(bytes, on: screen, at: now())
        show()
        if !engine.pending.isEmpty { host.predictionsNeedFrames() }
    }

    /// A write that was not a key's: its bytes are not known.
    func otherInput() {
        rollback()
    }

    /// One display frame while predictions wait. Returns whether it needs the next frame.
    // perf-hot: 0.05ms terminal-key
    func frame() -> Bool {
        guard let host, !engine.pending.isEmpty else { return false }
        guard canShow(host) else {
            rollback()
            return false
        }
        let at = now()
        let frameID = host.presentedFrameID
        let due = engine.deadline.map { at >= $0 } ?? false
        guard frameID != lastFrame || due else { return true }
        lastFrame = frameID
        if let screen = host.readPredictionGrid(row: engine.pending.first?.row, leftmost: leftmostColumn,
                                                readsBefore: false) {
            engine.update(conditions(host))
            engine.hostOutput(on: screen, at: at)
            engine.expire(on: screen, at: at)
        } else {
            engine.rollback()
        }
        show()
        return !engine.pending.isEmpty
    }

    /// Drops every prediction and starts a new epoch.
    func rollback() {
        engine.rollback()
        show()
    }

    private var leftmostColumn: Int? {
        engine.pending.map(\.column).min()
    }

    /// No input method composes, the background is opaque, and what shows is still where it was drawn.
    private func canShow(_ host: any PredictiveEchoHost) -> Bool {
        guard !host.isComposing, !host.isTranslucent else { return false }
        return (shown.cells.isEmpty && shown.cursor == nil) || host.predictionGeometry == shownGeometry
    }

    private func conditions(_ host: any PredictiveEchoHost) -> PredictiveEcho.Conditions {
        PredictiveEcho.Conditions(isRemoteSession: config.isRemoteSession, isSecureInput: host.isSecureInput)
    }

    private func show() {
        var cells: [PredictiveEcho.Cell] = []
        engine.forEachVisibleCell { cells.append($0) }
        let cursor = engine.predictedCursor
        // Ghostty still draws its cursor where the predictions began, a blank cell (the engine checked
        // the row): covered, so the person sees one cursor, the predicted one.
        if cursor != nil, let first = engine.pending.first,
           !cells.contains(where: { $0.row == first.row && $0.column == first.cursorBefore }) {
            cells.append(PredictiveEcho.Cell(row: first.row, column: first.cursorBefore, glyph: PredictiveEcho.blank))
        }
        guard cells != shown.cells || cursor != shown.cursor else { return }
        shown = (cells, cursor)
        shownGeometry = host?.predictionGeometry
        host?.showPredictions(cells, cursor: cursor)
    }
}
