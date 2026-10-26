/// What the echo predictor reads from the real terminal grid. The overlay (p04-input-046) reads it
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
///   never at the right margin, never on the alternate screen, never during secure input.
/// - Any other byte (escape, return, control, non-ASCII) or a typed byte the rules refuse drops
///   every prediction and starts a new ``PredictionEpoch``.
/// - Host output is matched against the predictions: the longest prefix whose cursor and cells
///   match the real grid is settled; no matching prefix, a cursor jump or the alternate screen
///   drops all of them.
/// - Predictions show only in a confirmed epoch and, in ``Mode/remote``, only for a remote session
///   or a smoothed echo RTT of 30 ms or more (off again below 20 ms, mosh's SRTT triggers).
///
/// The engine is a value with no side effects: it never writes to the PTY, the daemon or the grid,
/// so a rollback is exact: the overlay draws nothing and the real grid shows through.
nonisolated struct PredictiveEcho: Sendable {
    nonisolated enum Mode: Equatable, Sendable {
        /// Show for remote sessions and when the measured echo RTT is high.
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
    }

    private nonisolated enum Verdict {
        case mismatch
        /// Cursor and cells match, but no matched cell differs from what it showed before.
        case uncredited
        case credited
    }

    static let blank: UInt8 = 0x20
    static let delete: UInt8 = 0x7F
    /// mosh SRTT_TRIGGER_HIGH and SRTT_TRIGGER_LOW.
    static let rttShowThreshold: Duration = .milliseconds(30)
    static let rttHideThreshold: Duration = .milliseconds(20)
    /// More un-echoed keystrokes than this (a paste) are not predicted.
    static let maxPending = 32

    let mode: Mode
    /// How long a prediction may wait for its echo before ``expire(on:at:)`` settles it.
    let expiry: Duration
    private(set) var conditions = Conditions()
    private(set) var epoch = PredictionEpoch()
    private(set) var pending: [Prediction] = []
    private(set) var smoothedRTT: Duration?
    private(set) var isRTTTriggered = false

    init(mode: Mode, expiry: Duration = .seconds(2)) {
        self.mode = mode
        self.expiry = expiry
        pending.reserveCapacity(Self.maxPending)
    }

    /// True when the overlay should draw the predicted cells and cursor.
    var isShowing: Bool {
        guard epoch.isConfirmed, !pending.isEmpty, !conditions.isSecureInput else { return false }
        switch mode {
        case .always: return true
        case .remote: return conditions.isRemoteSession || isRTTTriggered
        }
    }

    /// The predicted cursor, while predictions show.
    var predictedCursor: Position? {
        guard isShowing, let last = pending.last else { return nil }
        return Position(row: last.row, column: last.cursorAfter)
    }

    /// When the oldest prediction expires; the overlay arms one timer for it.
    var deadline: ContinuousClock.Instant? {
        pending.first?.typedAt.advanced(by: expiry)
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

    /// Drops every prediction and starts an unconfirmed epoch.
    mutating func rollback() {
        pending.removeAll(keepingCapacity: true)
        epoch.advance()
    }

    /// The bytes one key sent to the PTY. A byte the rules refuse rolls back and ends the chunk.
    // perf-hot: 0.05ms terminal-key
    mutating func typed(_ bytes: some Sequence<UInt8>, on screen: some PredictionScreen,
                        at now: ContinuousClock.Instant) {
        guard canPredict(on: screen) else {
            rollback()
            return
        }
        for byte in bytes {
            guard predict(byte, on: screen, at: now) else {
                rollback()
                return
            }
        }
    }

    /// The grid after the host's output was parsed.
    // perf-hot: 0.05ms terminal-key
    mutating func hostOutput(on screen: some PredictionScreen, at now: ContinuousClock.Instant) {
        guard !pending.isEmpty else { return }
        guard canPredict(on: screen), screen.cursorRow == pending[0].row else {
            rollback()
            return
        }
        guard let match = echoMatch(on: screen) else {
            rollback()
            return
        }
        guard match.count > 0 else { return }
        let newest = pending[match.count - 1].typedAt
        pending.removeFirst(match.count)
        if match.credited {
            epoch.confirm()
            sampleRTT(newest.duration(to: now))
        }
    }

    /// At ``deadline``: predictions the grid already shows are settled quietly; any other
    /// overdue prediction is wrong (its echo never came) and rolls back.
    mutating func expire(on screen: some PredictionScreen, at now: ContinuousClock.Instant) {
        guard let deadline = deadline, now >= deadline else { return }
        let all = pending.count
        if canPredict(on: screen), screen.cursorRow == pending[0].row,
           pending[all - 1].cursorAfter == screen.cursorColumn,
           verdict(prefix: all, on: screen) != .mismatch {
            pending.removeAll(keepingCapacity: true)
        } else {
            rollback()
        }
    }

    private func canPredict(on screen: some PredictionScreen) -> Bool {
        !conditions.isSecureInput && !screen.isAlternateScreen
    }

    private mutating func predict(_ byte: UInt8, on screen: some PredictionScreen,
                                  at now: ContinuousClock.Instant) -> Bool {
        guard pending.count < Self.maxPending else { return false }
        let row = pending.last?.row ?? screen.cursorRow
        let column = pending.last?.cursorAfter ?? screen.cursorColumn
        // Each prediction leaves the cells from its cursor on blank, so only the first checks them.
        guard row >= 0, column >= 0, column < screen.columns,
              !pending.isEmpty || restOfRowIsBlank(row: row, from: column, on: screen) else { return false }
        switch byte {
        case 0x20...0x7E:
            // At the last column the glyph sets the pending wrap instead of moving the cursor.
            guard column + 1 < screen.columns else { return false }
            pending.append(Prediction(row: row, column: column, glyph: byte, replaced: Self.blank,
                                      cursorBefore: column, cursorAfter: column + 1, typedAt: now))
        case Self.delete:
            guard column > 0, let deleted = view(row: row, column: column - 1, on: screen) else { return false }
            pending.append(Prediction(row: row, column: column - 1, glyph: Self.blank, replaced: deleted,
                                      cursorBefore: column, cursorAfter: column - 1, typedAt: now))
        default:
            return false
        }
        return true
    }

    /// Only the end of a row is predicted: with text right of the cursor, an insert (shift right)
    /// and a zsh autosuggestion (overwrite) look the same until the echo.
    private func restOfRowIsBlank(row: Int, from column: Int, on screen: some PredictionScreen) -> Bool {
        var column = column
        while column < screen.columns {
            guard screen.glyph(row: row, column: column) == Self.blank else { return false }
            column += 1
        }
        return true
    }

    /// The cell as the predictions so far leave it.
    private func view(row: Int, column: Int, on screen: some PredictionScreen) -> UInt8? {
        if let latest = pending.last(where: { $0.row == row && $0.column == column }) { return latest.glyph }
        return screen.glyph(row: row, column: column)
    }

    /// The longest echoed prefix that changed a cell; else none echoed yet if the cursor has not
    /// moved (an unchanged cell proves nothing: "a" then backspace looks the same before and after
    /// its echo); else the longest prefix that matches without changing a cell. Nil is a mismatch.
    private func echoMatch(on screen: some PredictionScreen) -> (count: Int, credited: Bool)? {
        var credited: Int?
        var uncredited: Int?
        for count in 1...pending.count where pending[count - 1].cursorAfter == screen.cursorColumn {
            switch verdict(prefix: count, on: screen) {
            case .credited: credited = count
            case .uncredited: uncredited = count
            case .mismatch: continue
            }
        }
        if let credited { return (credited, true) }
        if screen.cursorColumn == pending[0].cursorBefore { return (0, false) }
        if let uncredited { return (uncredited, false) }
        return nil
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

    /// TCP-style smoothing (1/8 gain), as mosh's SRTT; the trigger turns off only between runs.
    private mutating func sampleRTT(_ sample: Duration) {
        let smoothed = smoothedRTT.map { $0 + (sample - $0) / 8 } ?? sample
        smoothedRTT = smoothed
        if smoothed >= Self.rttShowThreshold {
            isRTTTriggered = true
        } else if smoothed < Self.rttHideThreshold, pending.isEmpty {
            isRTTTriggered = false
        }
    }
}
