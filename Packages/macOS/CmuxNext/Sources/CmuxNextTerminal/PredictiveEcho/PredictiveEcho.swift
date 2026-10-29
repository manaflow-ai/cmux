/// What the echo predictor reads from the real terminal grid. The overlay reads it
/// from the live Ghostty surface; tests use plain structs.
nonisolated protocol PredictionScreen {
    var cursorRow: Int { get }
    var cursorColumn: Int { get }
    var columns: Int { get }
    var isAlternateScreen: Bool { get }
    /// The cell as one byte when it is blank (0x20) or single-width printable ASCII; nil for
    /// anything else (wide or combining text, a wide character's spacer).
    func glyph(row: Int, column: Int) -> UInt8?
}

/// Local echo prediction for slow terminals, after mosh's prediction engine
/// (src/frontend/terminaloverlay.cc). Chromium has no equivalent; this follows mosh's rules:
///
/// - Only printable ASCII and backspace (DEL, 0x7F) at the end of the cursor's row are predicted,
///   never at the right margin, never on the alternate screen, never during secure input. The row
///   right of the predictions must stay blank: it is checked on every keystroke and every echo,
///   because the host can draw there (an autosuggestion) without moving the cursor.
/// - Any other byte (escape, return, control, non-ASCII) or a typed byte the rules refuse starts a
///   new ``PredictionEpoch`` (mosh `become_tentative`). Predictions typed before it keep showing
///   until their echo settles them; nothing more is predicted until they have.
/// - Host output is matched against the predictions: the longest prefix whose cursor and cells
///   match the real grid is settled. A predicted cell showing another glyph at the cursor, a row
///   change, the alternate screen or text right of the predictions drops all of them. Any other
///   grid (a redraw split across reads) is not proof either way: the predictions wait for their
///   echo or ``deadline``, as mosh keeps a prediction pending until the host acknowledged it.
/// - Predictions show only in a confirmed epoch and, in ``Mode/remote``, only for a remote session,
///   a smoothed echo RTT above 30 ms (off again at or below 20 ms) or after an echo stalled for
///   250 ms (off again after 10 quick echoes): mosh's SRTT and glitch triggers.
///
/// The engine is a value with no side effects: it never writes to the PTY, the daemon or the grid,
/// so a rollback is exact: the overlay draws nothing and the real grid shows through.
nonisolated struct PredictiveEcho: Sendable {
    nonisolated enum Mode: Equatable, Sendable {
        /// Show for remote sessions, when the measured echo RTT is high, and after a stalled echo.
        case remote
        /// Show whenever the epoch is confirmed.
        case always
    }

    nonisolated struct Conditions: Equatable, Sendable {
        var isRemoteSession = false
        var isSecureInput = false
    }

    nonisolated struct Position: Equatable, Sendable {
        let row: Int
        let column: Int
    }

    nonisolated struct Cell: Equatable, Sendable {
        let row: Int
        let column: Int
        let glyph: UInt8
    }

    /// One predicted keystroke: it sets one cell and moves the cursor one column.
    nonisolated struct Prediction: Equatable, Sendable {
        let row: Int
        let column: Int
        let glyph: UInt8
        /// The cell's glyph before this prediction (the real one or an earlier prediction's).
        let replaced: UInt8
        let cursorBefore: Int
        let cursorAfter: Int
        let typedAt: ContinuousClock.Instant
        /// The ``PredictionEpoch`` id it was typed in (mosh `tentative_until_epoch`).
        let epoch: UInt64
    }

    private nonisolated enum Verdict {
        case mismatch
        /// Cursor and cells match, but no matched cell differs from what it showed before.
        case uncredited
        case credited
    }

    private nonisolated enum EchoMatch {
        /// The grid contradicts the predictions.
        case mismatch
        /// No echo yet, or a grid that proves nothing either way.
        case waiting
        case settled(count: Int, credited: Bool)
    }

    static let blank: UInt8 = 0x20
    static let delete: UInt8 = 0x7F
    /// mosh SRTT_TRIGGER_HIGH and SRTT_TRIGGER_LOW.
    static let rttShowThreshold: Duration = .milliseconds(30)
    static let rttHideThreshold: Duration = .milliseconds(20)
    /// mosh GLITCH_THRESHOLD, GLITCH_REPAIR_COUNT and GLITCH_REPAIR_MININTERVAL.
    static let glitchThreshold: Duration = .milliseconds(250)
    static let glitchRepairCount = 10
    static let glitchRepairInterval: Duration = .milliseconds(150)
    /// More un-echoed keystrokes than this (a paste) are not predicted.
    static let maxPending = 32

    let mode: Mode
    /// How long a prediction may wait for its echo before ``expire(on:at:)`` settles it.
    let expiry: Duration
    private(set) var conditions = Conditions()
    private(set) var epoch = PredictionEpoch()
    /// In typing order, all of one epoch: nothing is predicted after an epoch change until these settle.
    private(set) var pending: [Prediction] = []
    private(set) var smoothedRTT: Duration?
    private(set) var isRTTTriggered = false
    /// Quick echoes left before the glitch trigger turns off; above zero, ``Mode/remote`` shows.
    private(set) var glitchRepairsLeft = 0
    /// The newest prediction already counted as stalled.
    private var stalledThrough: ContinuousClock.Instant?
    private var lastQuickConfirmation: ContinuousClock.Instant?

    init(mode: Mode, expiry: Duration = .seconds(2)) {
        self.mode = mode
        self.expiry = expiry
        pending.reserveCapacity(Self.maxPending)
    }

    /// True when the overlay should draw the predicted cells.
    var isShowing: Bool {
        guard let first = pending.first, epoch.hasConfirmed(first.epoch), !conditions.isSecureInput else {
            return false
        }
        switch mode {
        case .always: return true
        case .remote: return conditions.isRemoteSession || isRTTTriggered || glitchRepairsLeft > 0
        }
    }

    /// The predicted cursor, while predictions show and no refused byte may have moved it.
    var predictedCursor: Position? {
        guard isShowing, !isBlocked, let last = pending.last else { return nil }
        return Position(row: last.row, column: last.cursorAfter)
    }

    /// When ``expire(on:at:)`` is next due: the oldest prediction's stall check, else its expiry.
    /// The overlay arms one timer for it.
    var deadline: ContinuousClock.Instant? {
        guard let first = pending.first else { return nil }
        let expiresAt = first.typedAt.advanced(by: expiry)
        guard let unchecked = pending.first(where: { prediction in
            stalledThrough.map { prediction.typedAt > $0 } ?? true
        }) else { return expiresAt }
        return min(expiresAt, unchecked.typedAt.advanced(by: Self.glitchThreshold))
    }

    /// Calls `body` once per predicted cell to draw, with its latest predicted glyph.
    func forEachVisibleCell(_ body: (Cell) -> Void) {
        guard isShowing else { return }
        for index in pending.indices where !isOverridden(index, before: pending.count) {
            let prediction = pending[index]
            body(Cell(row: prediction.row, column: prediction.column, glyph: prediction.glyph))
        }
    }

    mutating func update(_ conditions: Conditions) {
        self.conditions = conditions
        if conditions.isSecureInput { rollback() }
    }

    /// Drops every prediction and starts an unconfirmed epoch (mosh `reset`).
    mutating func rollback() {
        pending.removeAll(keepingCapacity: true)
        epoch.advance()
    }

    /// The bytes one key sent to the PTY. A byte the rules refuse starts a new epoch and ends the chunk.
    // perf-hot: 0.05ms terminal-key
    mutating func typed(_ bytes: some Sequence<UInt8>, on screen: some PredictionScreen,
                        at now: ContinuousClock.Instant) {
        guard canPredict(on: screen), rowIsClear(on: screen) else {
            rollback()
            return
        }
        for byte in bytes {
            guard predict(byte, on: screen, at: now) else {
                epoch.advance()
                return
            }
        }
    }

    /// The grid after the host's output was parsed.
    // perf-hot: 0.05ms terminal-key
    mutating func hostOutput(on screen: some PredictionScreen, at now: ContinuousClock.Instant) {
        guard let first = pending.first else { return }
        noteStall(at: now)
        guard canPredict(on: screen) else {
            rollback()
            return
        }
        guard screen.cursorRow == first.row else {
            // After a refused byte (a return, an arrow) the host may move the cursor off the row;
            // the epoch already changed, so the predictions just retire. Otherwise it is a jump.
            if isBlocked {
                pending.removeAll(keepingCapacity: true)
            } else {
                rollback()
            }
            return
        }
        switch echoMatch(on: screen) {
        case .mismatch:
            rollback()
            return
        case .waiting:
            break
        case let .settled(count, credited):
            guard count > 0, count <= pending.count else { rollback(); return }
            let oldest = first.typedAt
            let newest = pending[count - 1]
            pending.removeFirst(count)
            if credited { confirm(newest, oldest: oldest, at: now) }
        }
        if !pending.isEmpty, !rowIsClear(on: screen) { rollback() }
    }

    /// At ``deadline``: a prediction still unechoed after 250 ms turns the glitch trigger on. At its
    /// expiry, predictions the grid already shows are settled quietly; any other overdue prediction
    /// is wrong (its echo never came) and rolls back.
    mutating func expire(on screen: some PredictionScreen, at now: ContinuousClock.Instant) {
        guard let first = pending.first else { return }
        noteStall(at: now)
        guard now >= first.typedAt.advanced(by: expiry) else { return }
        let all = pending.count
        if canPredict(on: screen), screen.cursorRow == first.row,
           pending[all - 1].cursorAfter == screen.cursorColumn,
           verdict(prefix: all, on: screen) != .mismatch {
            pending.removeAll(keepingCapacity: true)
        } else {
            rollback()
        }
    }

    /// True after a refused byte: the pending predictions belong to an earlier epoch.
    private var isBlocked: Bool {
        guard let last = pending.last else { return false }
        return last.epoch != epoch.id
    }

    private func canPredict(on screen: some PredictionScreen) -> Bool {
        !conditions.isSecureInput && !screen.isAlternateScreen
    }

    private mutating func predict(_ byte: UInt8, on screen: some PredictionScreen,
                                  at now: ContinuousClock.Instant) -> Bool {
        guard pending.count < Self.maxPending, !isBlocked else { return false }
        let row = pending.last?.row ?? screen.cursorRow
        let column = pending.last?.cursorAfter ?? screen.cursorColumn
        guard row >= 0, column >= 0, column < screen.columns else { return false }
        switch byte {
        case 0x20...0x7E:
            // At the last column the glyph sets the pending wrap instead of moving the cursor.
            guard column + 1 < screen.columns else { return false }
            pending.append(Prediction(row: row, column: column, glyph: byte, replaced: Self.blank,
                                      cursorBefore: column, cursorAfter: column + 1, typedAt: now,
                                      epoch: epoch.id))
        case Self.delete:
            guard column > 0, let deleted = view(row: row, column: column - 1, on: screen) else { return false }
            pending.append(Prediction(row: row, column: column - 1, glyph: Self.blank, replaced: deleted,
                                      cursorBefore: column, cursorAfter: column - 1, typedAt: now,
                                      epoch: epoch.id))
        default:
            return false
        }
        return true
    }

    /// Only the end of a row is predicted: with text right of the cursor, an insert (shift right)
    /// and a zsh autosuggestion (overwrite) look the same until the echo. Every real cell from where
    /// the predictions start (else the cursor) to the right margin is blank or already shows a
    /// glyph a prediction puts there.
    private func rowIsClear(on screen: some PredictionScreen) -> Bool {
        let row = pending.first?.row ?? screen.cursorRow
        var column = pending.first?.cursorBefore ?? screen.cursorColumn
        while column < screen.columns {
            let glyph = screen.glyph(row: row, column: column)
            if glyph != Self.blank, !pending.contains(where: { $0.column == column && $0.glyph == glyph }) {
                return false
            }
            column += 1
        }
        return true
    }

    /// The cell as the predictions so far leave it.
    private func view(row: Int, column: Int, on screen: some PredictionScreen) -> UInt8? {
        if let latest = pending.last(where: { $0.row == row && $0.column == column }) { return latest.glyph }
        return screen.glyph(row: row, column: column)
    }

    /// The longest echoed prefix that changed a cell (after a refused byte, wherever the cursor
    /// went); else none echoed yet if the cursor has not moved (an unchanged cell proves nothing:
    /// "a" then backspace looks the same before and after its echo); else the longest prefix that
    /// matches without changing a cell. A mismatch needs the cursor where a prefix leaves it.
    private func echoMatch(on screen: some PredictionScreen) -> EchoMatch {
        var credited: Int?
        var uncredited: Int?
        var contradicted = false
        let blocked = isBlocked
        for count in 1...pending.count {
            let atCursor = pending[count - 1].cursorAfter == screen.cursorColumn
            guard atCursor || blocked else { continue }
            switch verdict(prefix: count, on: screen) {
            case .credited: credited = count
            case .uncredited where atCursor: uncredited = count
            case .mismatch where atCursor: contradicted = true
            case .uncredited, .mismatch: continue
            }
        }
        if let credited { return .settled(count: credited, credited: true) }
        if screen.cursorColumn == pending[0].cursorBefore { return .waiting }
        if let uncredited { return .settled(count: uncredited, credited: false) }
        return contradicted ? .mismatch : .waiting
    }

    /// Whether the grid shows the first `count` predictions: each cell they set has its last
    /// predicted glyph. Credited when one of those cells differs from what it showed before them.
    private func verdict(prefix count: Int, on screen: some PredictionScreen) -> Verdict {
        var credited = false
        for index in 0..<count where !isOverridden(index, before: count) {
            let prediction = pending[index]
            guard prediction.column < screen.columns,
                  screen.glyph(row: prediction.row, column: prediction.column) == prediction.glyph else {
                return .mismatch
            }
            if let first = pending.first(where: { $0.column == prediction.column }),
               first.replaced != prediction.glyph {
                credited = true
            }
        }
        return credited ? .credited : .uncredited
    }

    /// True when a later prediction before `end` sets the same cell.
    private func isOverridden(_ index: Int, before end: Int) -> Bool {
        let column = pending[index].column
        var later = index + 1
        while later < end {
            if pending[later].column == column { return true }
            later += 1
        }
        return false
    }

    /// mosh `cull`: a prediction pending for `glitchThreshold` or more turns the glitch trigger on.
    private mutating func noteStall(at now: ContinuousClock.Instant) {
        let threshold = Self.glitchThreshold
        guard let stalled = pending.last(where: { $0.typedAt.duration(to: now) >= threshold }) else { return }
        glitchRepairsLeft = Self.glitchRepairCount
        stalledThrough = stalled.typedAt
    }

    /// A credited echo of predictions typed from `oldest` to `newest`: confirms their epoch, samples
    /// the RTT and, when all came back quickly, repairs the glitch trigger by one, at most once per
    /// `glitchRepairInterval` (mosh `last_quick_confirmation`).
    private mutating func confirm(_ newest: Prediction, oldest: ContinuousClock.Instant,
                                  at now: ContinuousClock.Instant) {
        epoch.confirm(newest.epoch)
        if glitchRepairsLeft > 0, oldest.duration(to: now) < Self.glitchThreshold,
           lastQuickConfirmation.map({ $0.duration(to: now) >= Self.glitchRepairInterval }) ?? true {
            glitchRepairsLeft -= 1
            lastQuickConfirmation = now
        }
        sampleRTT(newest.typedAt.duration(to: now))
    }

    /// TCP-style smoothing (1/8 gain), as mosh's SRTT; the trigger turns off only between runs.
    private mutating func sampleRTT(_ sample: Duration) {
        let smoothed = smoothedRTT.map { $0 + (sample - $0) / 8 } ?? sample
        smoothedRTT = smoothed
        if smoothed > Self.rttShowThreshold {
            isRTTTriggered = true
        } else if smoothed <= Self.rttHideThreshold, pending.isEmpty {
            isRTTTriggered = false
        }
    }
}
