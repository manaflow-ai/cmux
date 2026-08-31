public import CMUXMobileCore
public import Foundation

/// Mosh-style local echo prediction for one mirrored terminal surface.
///
/// The engine is a pure value type: callers feed it typed input
/// (``registerKeystrokes(_:at:)``), Mac input acknowledgments
/// (``acknowledgeInput(untilSeq:)``), and delivered authoritative render-grid
/// frames (``reconcile(_:at:)``), all with explicit timestamps, and read the
/// renderable result from ``overlay``. Nothing here touches a clock, the
/// network, or UI, so every transition is deterministic under test.
///
/// State machine:
///
/// - **Per prediction**: `pending` → confirmed (authoritative cell matches; the
///   cell leaves the overlay) or the whole epoch dies. There is no per-cell
///   incorrect state: a contradiction, expiry, or unsafe input invalidates the
///   entire epoch, mosh's `become_tentative` semantics.
/// - **Epoch invalidation** is either *neutral* (control input, line break,
///   paste burst, scroll-off, alternate screen, unjudgeable row) or a
///   *mispredict* (a sequence-qualified frame contradicts a predicted cell or
///   the predicted cursor). Only mispredicts escalate the cooldown backoff.
/// - **Display** (`tentative` ⇄ `active`): predictions are always tracked, but
///   drawn only after ``Configuration/activationConfirmStreak`` consecutive
///   confirmations while no cooldown is running. A mispredict or an expiry
///   (no-echo detection: the echo never arrived, e.g. a password prompt) drops
///   display back to `tentative`. This is mosh's adaptive engagement: in a
///   no-echo context predictions keep expiring silently and the overlay stays
///   hidden; the first confirmed echoes re-arm it.
public struct MobileEchoPredictionEngine: Equatable, Sendable {
    public struct Configuration: Equatable, Sendable {
        /// How long a prediction may wait for authoritative coverage before it
        /// is treated as "this context does not echo".
        public var confirmationTimeout: TimeInterval
        /// First mispredict cooldown; doubles per consecutive mispredict.
        public var cooldownBase: TimeInterval
        /// Cooldown growth cap.
        public var cooldownMax: TimeInterval
        /// Consecutive confirmations required before the overlay displays.
        public var activationConfirmStreak: Int
        /// Outstanding-cell cap; overflowing input neutrally invalidates.
        public var maximumPendingCells: Int
        /// A chunk with more scalars than this is treated as a paste, which is
        /// never predicted (its echo timing and rendering are shell-defined).
        public var maximumPredictableChunkScalarCount: Int

        public init(
            confirmationTimeout: TimeInterval = 0.6,
            cooldownBase: TimeInterval = 0.5,
            cooldownMax: TimeInterval = 8.0,
            activationConfirmStreak: Int = 2,
            maximumPendingCells: Int = 64,
            maximumPredictableChunkScalarCount: Int = 32
        ) {
            self.confirmationTimeout = confirmationTimeout
            self.cooldownBase = cooldownBase
            self.cooldownMax = cooldownMax
            self.activationConfirmStreak = activationConfirmStreak
            self.maximumPendingCells = maximumPendingCells
            self.maximumPredictableChunkScalarCount = maximumPredictableChunkScalarCount
        }
    }

    /// Why one keystroke was not predicted.
    public enum SuppressionReason: Equatable, Sendable {
        /// No authoritative frame has been reconciled yet.
        case noBaseline
        /// The surface shows the alternate screen (full-screen TUI).
        case alternateScreen
        /// A mouse-tracking mode is set; a TUI owns the primary screen.
        case mouseTracking
        /// The authoritative cursor is hidden.
        case cursorHidden
        /// No cursor position is known.
        case noCursor
        /// Predicting would wrap past the last column.
        case wouldWrap
        /// The outstanding-cell cap was hit.
        case pendingOverflow
        /// The chunk looked like a paste.
        case pasteBurst
        /// The token is non-printing (control, escape sequence, line break).
        case nonPrinting
    }

    /// What one input chunk did to the engine.
    public struct KeystrokeOutcome: Equatable, Sendable {
        public var predictedCellCount: Int
        /// Backspaces that retracted a same-epoch predicted cell.
        public var retractedCellCount: Int
        public var suppressed: [SuppressionReason]
        /// Whether the chunk neutrally invalidated the epoch.
        public var invalidatedEpoch: Bool
        public var overlayChanged: Bool
    }

    /// What one authoritative update did to the engine.
    public struct ReconcileOutcome: Equatable, Sendable {
        public var confirmedCellCount: Int
        public var mispredicted: Bool
        public var expiredCellCount: Int
        public var overlayChanged: Bool
    }

    struct PendingCell: Equatable, Sendable {
        var row: Int
        var column: Int
        var character: Character
        var epoch: UInt64
        var registeredAt: TimeInterval
        /// The Mac state sequence known to include this input, from the input
        /// acknowledgment. A frame may only *contradict* the prediction once
        /// its `stateSeq` reaches this; earlier frames simply predate the echo.
        var minimumAuthoritativeSeq: UInt64?
    }

    struct Context: Equatable, Sendable {
        var columns = 0
        var rows = 0
        var cursorRow: Int?
        var cursorColumn: Int?
        var cursorVisible = true
        var activeScreen = MobileTerminalRenderGridFrame.Screen.primary
        var mouseTrackingActive = false
        var hasBaseline = false
    }

    public var configuration: Configuration

    private(set) var context = Context()
    public private(set) var epoch: UInt64 = 1
    private(set) var pending: [PendingCell] = []
    private var predictedCursorRow: Int?
    private var predictedCursorColumn: Int?
    private var displayState = MobileEchoPredictionOverlay.DisplayState.tentative
    private var confirmStreak = 0
    private var consecutiveMispredicts = 0
    private var cooldownUntil: TimeInterval?
    /// The state sequence at which the predicted cursor becomes judgeable.
    /// Registering input clears it (that input has no acknowledgment yet);
    /// the next acknowledgment restores it. This blocks a false cursor
    /// mispredict when an early match confirms a cell before its input's
    /// acknowledgment has arrived.
    private var cursorQualificationSeq: UInt64?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The renderable snapshot of the current prediction state.
    public var overlay: MobileEchoPredictionOverlay {
        MobileEchoPredictionOverlay(
            displayState: displayState,
            epoch: epoch,
            cells: pending.map {
                MobileEchoPredictionOverlay.Cell(row: $0.row, column: $0.column, character: $0.character)
            },
            predictedCursorRow: predictedCursorRow,
            predictedCursorColumn: predictedCursorColumn
        )
    }

    // MARK: - Input

    /// Classifies one chunk of typed input and registers predictions for the
    /// safe printable characters in it.
    public mutating func registerKeystrokes(
        _ text: String,
        at now: TimeInterval
    ) -> KeystrokeOutcome {
        var outcome = KeystrokeOutcome(
            predictedCellCount: 0,
            retractedCellCount: 0,
            suppressed: [],
            invalidatedEpoch: false,
            overlayChanged: false
        )
        guard !text.isEmpty else { return outcome }
        _ = expireOverduePredictions(at: now, into: &outcome)

        if text.unicodeScalars.count > configuration.maximumPredictableChunkScalarCount {
            outcome.suppressed.append(.pasteBurst)
            invalidateEpochNeutrally(into: &outcome)
            return outcome
        }
        for token in MobileEchoPredictionInputTokenizer.tokenize(text) {
            switch token {
            case .printable(let character):
                registerPrintable(character, at: now, into: &outcome)
            case .backspace:
                registerBackspace(into: &outcome)
            case .lineBreak, .control:
                outcome.suppressed.append(.nonPrinting)
                invalidateEpochNeutrally(into: &outcome)
            }
        }
        return outcome
    }

    /// Records the Mac's input acknowledgment: `seq` is the terminal state
    /// sequence that includes all input sent so far, so every outstanding
    /// prediction without a qualification floor adopts it.
    public mutating func acknowledgeInput(untilSeq seq: UInt64) {
        cursorQualificationSeq = max(cursorQualificationSeq ?? 0, seq)
        for index in pending.indices where pending[index].minimumAuthoritativeSeq == nil {
            pending[index].minimumAuthoritativeSeq = seq
        }
    }

    // MARK: - Reconciliation

    /// Judges outstanding predictions against one delivered authoritative
    /// frame, then adopts the frame as the new grid context.
    public mutating func reconcile(
        _ update: MobileEchoAuthoritativeUpdate,
        at now: TimeInterval
    ) -> ReconcileOutcome {
        var outcome = ReconcileOutcome(
            confirmedCellCount: 0,
            mispredicted: false,
            expiredCellCount: 0,
            overlayChanged: false
        )

        if update.activeScreen == .alternate {
            if !pending.isEmpty || predictedCursorRow != nil {
                dropEpoch(into: &outcome)
            }
            becomeTentative()
            adoptContext(update)
            return outcome
        }

        shiftForScroll(update.scrolledRows, into: &outcome)
        judgePendingCells(against: update, at: now, into: &outcome)
        if !outcome.mispredicted {
            judgePredictedCursor(against: update, at: now, into: &outcome)
        }
        _ = expireOverduePredictions(at: now, into: &outcome)
        adoptContext(update)
        if pending.isEmpty, !outcome.mispredicted {
            // Nothing outstanding: the authoritative cursor is the truth again.
            resetPredictedCursor(into: &outcome)
        }
        return outcome
    }

    /// Expires predictions that outlived ``Configuration/confirmationTimeout``
    /// without authoritative coverage — the no-echo signal. Returns whether the
    /// overlay changed.
    @discardableResult
    public mutating func expireOverduePredictions(at now: TimeInterval) -> Bool {
        var outcome = ReconcileOutcome(
            confirmedCellCount: 0,
            mispredicted: false,
            expiredCellCount: 0,
            overlayChanged: false
        )
        return expireOverduePredictions(at: now, into: &outcome)
    }

    /// Drops all prediction state without penalty. Call on stream resets,
    /// replay barriers, reconnects, and surface focus changes, where the local
    /// grid is about to be replaced wholesale.
    public mutating func invalidateForStreamReset() {
        pending.removeAll()
        epoch &+= 1
        predictedCursorRow = nil
        predictedCursorColumn = nil
        cursorQualificationSeq = nil
        becomeTentative()
        context.hasBaseline = false
    }

    // MARK: - Printable registration

    private mutating func registerPrintable(
        _ character: Character,
        at now: TimeInterval,
        into outcome: inout KeystrokeOutcome
    ) {
        if let reason = contextSuppressionReason() {
            outcome.suppressed.append(reason)
            return
        }
        guard let cursorRow = predictedCursorRow ?? context.cursorRow,
              let cursorColumn = predictedCursorColumn ?? context.cursorColumn else {
            outcome.suppressed.append(.noCursor)
            return
        }
        // Never predict a wrap: at the last column the echo's landing position
        // depends on autowrap and the app, so the epoch goes tentative instead.
        guard cursorColumn < context.columns - 1 else {
            outcome.suppressed.append(.wouldWrap)
            invalidateEpochNeutrally(into: &outcome)
            return
        }
        guard pending.count < configuration.maximumPendingCells else {
            outcome.suppressed.append(.pendingOverflow)
            invalidateEpochNeutrally(into: &outcome)
            return
        }
        pending.append(
            PendingCell(
                row: cursorRow,
                column: cursorColumn,
                character: character,
                epoch: epoch,
                registeredAt: now,
                minimumAuthoritativeSeq: nil
            )
        )
        predictedCursorRow = cursorRow
        predictedCursorColumn = cursorColumn + 1
        cursorQualificationSeq = nil
        outcome.predictedCellCount += 1
        outcome.overlayChanged = true
    }

    private mutating func registerBackspace(into outcome: inout KeystrokeOutcome) {
        // Only a backspace over a cell this epoch itself predicted is retracted
        // locally; erasing pre-existing content is left to the authoritative
        // echo, because the shell's redraw behavior there is not predictable.
        if let last = pending.last,
           let cursorRow = predictedCursorRow,
           let cursorColumn = predictedCursorColumn,
           last.row == cursorRow,
           last.column == cursorColumn - 1 {
            pending.removeLast()
            predictedCursorRow = last.row
            predictedCursorColumn = last.column
            cursorQualificationSeq = nil
            outcome.retractedCellCount += 1
            outcome.overlayChanged = true
        } else {
            outcome.suppressed.append(.nonPrinting)
            invalidateEpochNeutrally(into: &outcome)
        }
    }

    private func contextSuppressionReason() -> SuppressionReason? {
        guard context.hasBaseline else { return .noBaseline }
        if context.activeScreen == .alternate { return .alternateScreen }
        if context.mouseTrackingActive { return .mouseTracking }
        if !context.cursorVisible { return .cursorHidden }
        return nil
    }

    // MARK: - Judgment

    private mutating func judgePendingCells(
        against update: MobileEchoAuthoritativeUpdate,
        at now: TimeInterval,
        into outcome: inout ReconcileOutcome
    ) {
        var index = 0
        while index < pending.count {
            let cell = pending[index]
            guard update.coveredRows.contains(cell.row) else {
                index += 1
                continue
            }
            guard update.rowIsColumnAddressable(cell.row) else {
                // Double-width content broke column arithmetic; the epoch can
                // no longer be judged, so it dies neutrally.
                dropEpoch(into: &outcome)
                becomeTentative()
                return
            }
            let actual = update.character(atRow: cell.row, column: cell.column)
            if actual == cell.character {
                pending.remove(at: index)
                recordConfirmation(at: now)
                outcome.confirmedCellCount += 1
                outcome.overlayChanged = true
                continue
            }
            if isQualified(cell, by: update) {
                recordMispredict(at: now, into: &outcome)
                return
            }
            // The frame predates the echo of this input; keep waiting.
            index += 1
        }
    }

    /// A frame may contradict a prediction only once it provably includes the
    /// input: at or past the acknowledged sequence for that cell.
    private func isQualified(
        _ cell: PendingCell,
        by update: MobileEchoAuthoritativeUpdate
    ) -> Bool {
        guard let minimumSeq = cell.minimumAuthoritativeSeq else { return false }
        return update.stateSeq >= minimumSeq
    }

    private mutating func judgePredictedCursor(
        against update: MobileEchoAuthoritativeUpdate,
        at now: TimeInterval,
        into outcome: inout ReconcileOutcome
    ) {
        // Once every prediction is settled and the frame provably includes all
        // acknowledged input, the authoritative cursor must sit where the
        // predictions put it; anywhere else means the app moved it (readline
        // redraw, prompt rewrite) and the prediction model is wrong.
        guard pending.isEmpty,
              let predictedRow = predictedCursorRow,
              let predictedColumn = predictedCursorColumn,
              let qualificationSeq = cursorQualificationSeq,
              update.stateSeq >= qualificationSeq,
              let cursorRow = update.cursorRow,
              let cursorColumn = update.cursorColumn else {
            return
        }
        if cursorRow != predictedRow || cursorColumn != predictedColumn {
            recordMispredict(at: now, into: &outcome)
        } else {
            resetPredictedCursor(into: &outcome)
        }
    }

    private mutating func shiftForScroll(
        _ scrolledRows: Int,
        into outcome: inout ReconcileOutcome
    ) {
        guard scrolledRows > 0 else { return }
        guard !pending.isEmpty || predictedCursorRow != nil else { return }
        outcome.overlayChanged = true
        pending = pending.compactMap { cell in
            var shifted = cell
            shifted.row -= scrolledRows
            return shifted.row >= 0 ? shifted : nil
        }
        if let row = predictedCursorRow {
            let shifted = row - scrolledRows
            if shifted >= 0 {
                predictedCursorRow = shifted
            } else {
                predictedCursorRow = nil
                predictedCursorColumn = nil
            }
        }
    }

    private mutating func expireOverduePredictions(
        at now: TimeInterval,
        into outcome: inout ReconcileOutcome
    ) -> Bool {
        guard let oldest = pending.first,
              now - oldest.registeredAt >= configuration.confirmationTimeout else {
            return false
        }
        // One expired prediction poisons the epoch: this context is not
        // echoing (password prompt, stopped foreground process). Display goes
        // tentative; later predictions keep tracking silently and re-arm the
        // overlay when echoes return.
        outcome.expiredCellCount += pending.count
        dropEpoch(into: &outcome)
        becomeTentative()
        return true
    }

    private mutating func expireOverduePredictions(
        at now: TimeInterval,
        into outcome: inout KeystrokeOutcome
    ) -> Bool {
        var reconcile = ReconcileOutcome(
            confirmedCellCount: 0,
            mispredicted: false,
            expiredCellCount: 0,
            overlayChanged: false
        )
        let expired = expireOverduePredictions(at: now, into: &reconcile)
        if reconcile.overlayChanged {
            outcome.overlayChanged = true
        }
        return expired
    }

    // MARK: - Epoch and display transitions

    private mutating func recordConfirmation(at now: TimeInterval) {
        confirmStreak += 1
        consecutiveMispredicts = 0
        if let cooldown = cooldownUntil, now >= cooldown {
            cooldownUntil = nil
        }
        if displayState == .tentative,
           cooldownUntil == nil,
           confirmStreak >= configuration.activationConfirmStreak {
            displayState = .active
        }
    }

    private mutating func recordMispredict(
        at now: TimeInterval?,
        into outcome: inout ReconcileOutcome
    ) {
        outcome.mispredicted = true
        dropEpoch(into: &outcome)
        becomeTentative()
        consecutiveMispredicts += 1
        if let now {
            let exponent = min(consecutiveMispredicts - 1, 16)
            let cooldown = min(
                configuration.cooldownBase * pow(2, Double(exponent)),
                configuration.cooldownMax
            )
            cooldownUntil = now + cooldown
        }
    }

    private mutating func invalidateEpochNeutrally(into outcome: inout KeystrokeOutcome) {
        outcome.invalidatedEpoch = true
        if !pending.isEmpty || predictedCursorRow != nil {
            outcome.overlayChanged = true
        }
        pending.removeAll()
        epoch &+= 1
        predictedCursorRow = nil
        predictedCursorColumn = nil
        // Neutral invalidation keeps display and streak: typing "ls\r" then
        // more text should keep displaying immediately.
    }

    private mutating func dropEpoch(into outcome: inout ReconcileOutcome) {
        if !pending.isEmpty || predictedCursorRow != nil {
            outcome.overlayChanged = true
        }
        pending.removeAll()
        epoch &+= 1
        predictedCursorRow = nil
        predictedCursorColumn = nil
    }

    private mutating func becomeTentative() {
        displayState = .tentative
        confirmStreak = 0
    }

    private mutating func resetPredictedCursor(into outcome: inout ReconcileOutcome) {
        if predictedCursorRow != nil || predictedCursorColumn != nil {
            predictedCursorRow = nil
            predictedCursorColumn = nil
            outcome.overlayChanged = true
        }
    }

    private mutating func adoptContext(_ update: MobileEchoAuthoritativeUpdate) {
        context.columns = update.columns
        context.rows = update.rows
        if let cursorRow = update.cursorRow, let cursorColumn = update.cursorColumn {
            context.cursorRow = cursorRow
            context.cursorColumn = cursorColumn
            context.cursorVisible = update.cursorVisible
        }
        context.activeScreen = update.activeScreen
        if update.modesAuthoritative {
            context.mouseTrackingActive = update.mouseTrackingActive
        }
        context.hasBaseline = true
    }
}
