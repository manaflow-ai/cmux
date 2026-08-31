import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileEchoPredictionEngineTests {
    private func update(
        seq: UInt64,
        full: Bool = true,
        screen: MobileTerminalRenderGridFrame.Screen = .primary,
        columns: Int = 80,
        rows: Int = 24,
        cursor: (row: Int, column: Int)? = (0, 0),
        cursorVisible: Bool = true,
        mouseTracking: Bool = false,
        modesAuthoritative: Bool? = nil,
        scrolledRows: Int = 0,
        coveredRows: Set<Int>? = nil,
        rowTexts: [Int: String] = [:]
    ) -> MobileEchoAuthoritativeUpdate {
        MobileEchoAuthoritativeUpdate(
            stateSeq: seq,
            isFull: full,
            activeScreen: screen,
            columns: columns,
            rows: rows,
            cursorRow: cursor?.row,
            cursorColumn: cursor?.column,
            cursorVisible: cursorVisible,
            mouseTrackingActive: mouseTracking,
            modesAuthoritative: modesAuthoritative ?? full,
            scrolledRows: scrolledRows,
            coveredRows: coveredRows ?? (full ? Set(0..<rows) : Set(rowTexts.keys)),
            rowTexts: rowTexts
        )
    }

    /// An engine with a reconciled primary-screen baseline, cursor at `cursor`.
    private func baselineEngine(
        configuration: MobileEchoPredictionEngine.Configuration = .init(),
        cursor: (row: Int, column: Int) = (0, 0),
        columns: Int = 80
    ) -> MobileEchoPredictionEngine {
        var engine = MobileEchoPredictionEngine(configuration: configuration)
        _ = engine.reconcile(update(seq: 1, columns: columns, cursor: cursor), at: 0)
        return engine
    }

    /// Drives the engine to an `active` display state via two confirmed
    /// single-character predictions ("l", then "s"), ending at seq `12` with
    /// the cursor at (0, 2).
    private func activatedEngine() -> MobileEchoPredictionEngine {
        var engine = baselineEngine()
        _ = engine.registerKeystrokes("l", at: 0.1)
        engine.acknowledgeInput(untilSeq: 11)
        var outcome = engine.reconcile(
            update(seq: 11, cursor: (0, 1), rowTexts: [0: "l"]),
            at: 0.15
        )
        #expect(outcome.confirmedCellCount == 1)
        _ = engine.registerKeystrokes("s", at: 0.2)
        engine.acknowledgeInput(untilSeq: 12)
        outcome = engine.reconcile(
            update(seq: 12, cursor: (0, 2), rowTexts: [0: "ls"]),
            at: 0.25
        )
        #expect(outcome.confirmedCellCount == 1)
        #expect(engine.overlay.displayState == .active)
        return engine
    }

    // MARK: - Safety classification in context

    @Test func suppressesWithoutBaseline() {
        var engine = MobileEchoPredictionEngine()
        let outcome = engine.registerKeystrokes("a", at: 0)
        #expect(outcome.predictedCellCount == 0)
        #expect(outcome.suppressed == [.noBaseline])
        #expect(engine.overlay.cells.isEmpty)
    }

    @Test func predictsPrintableRunAtCursor() {
        var engine = baselineEngine(cursor: (3, 5))
        let outcome = engine.registerKeystrokes("ls", at: 0.1)
        #expect(outcome.predictedCellCount == 2)
        #expect(outcome.overlayChanged)
        #expect(
            engine.overlay.cells == [
                MobileEchoPredictionOverlay.Cell(row: 3, column: 5, character: "l"),
                MobileEchoPredictionOverlay.Cell(row: 3, column: 6, character: "s"),
            ]
        )
        #expect(engine.overlay.predictedCursorRow == 3)
        #expect(engine.overlay.predictedCursorColumn == 7)
        // No confirmation history yet: tracked, not displayed.
        #expect(engine.overlay.displayState == .tentative)
        #expect(!engine.overlay.isVisible)
    }

    @Test func suppressesOnAlternateScreen() {
        var engine = MobileEchoPredictionEngine()
        _ = engine.reconcile(update(seq: 1, screen: .alternate), at: 0)
        let outcome = engine.registerKeystrokes("a", at: 0.1)
        #expect(outcome.predictedCellCount == 0)
        #expect(outcome.suppressed == [.alternateScreen])
    }

    @Test func enteringAlternateScreenDropsPredictions() {
        var engine = activatedEngine()
        _ = engine.registerKeystrokes("x", at: 0.3)
        #expect(engine.overlay.cells.count == 1)
        let outcome = engine.reconcile(update(seq: 13, screen: .alternate), at: 0.35)
        #expect(outcome.overlayChanged)
        #expect(!outcome.mispredicted)
        #expect(engine.overlay.cells.isEmpty)
        #expect(engine.overlay.displayState == .tentative)
    }

    @Test func suppressesUnderMouseTracking() {
        var engine = MobileEchoPredictionEngine()
        _ = engine.reconcile(update(seq: 1, mouseTracking: true), at: 0)
        let outcome = engine.registerKeystrokes("a", at: 0.1)
        #expect(outcome.suppressed == [.mouseTracking])

        // A delta frame carries no mode state and must not clear the signal.
        _ = engine.reconcile(
            update(seq: 2, full: false, modesAuthoritative: false, rowTexts: [1: "x"]),
            at: 0.2
        )
        let afterDelta = engine.registerKeystrokes("a", at: 0.3)
        #expect(afterDelta.suppressed == [.mouseTracking])

        // A full frame with tracking off re-enables prediction.
        _ = engine.reconcile(update(seq: 3), at: 0.4)
        let afterFull = engine.registerKeystrokes("a", at: 0.5)
        #expect(afterFull.predictedCellCount == 1)
    }

    @Test func suppressesWhenCursorHidden() {
        var engine = MobileEchoPredictionEngine()
        _ = engine.reconcile(update(seq: 1, cursorVisible: false), at: 0)
        let outcome = engine.registerKeystrokes("a", at: 0.1)
        #expect(outcome.suppressed == [.cursorHidden])
    }

    @Test func neverPredictsWrapAtLastColumn() {
        var engine = baselineEngine(cursor: (0, 8), columns: 10)
        let first = engine.registerKeystrokes("a", at: 0.1)
        #expect(first.predictedCellCount == 1)
        #expect(engine.overlay.predictedCursorColumn == 9)
        let second = engine.registerKeystrokes("b", at: 0.2)
        #expect(second.predictedCellCount == 0)
        #expect(second.suppressed == [.wouldWrap])
        #expect(second.invalidatedEpoch)
        #expect(engine.overlay.cells.isEmpty)
    }

    @Test func lineBreakInvalidatesEpochNeutrally() {
        var engine = activatedEngine()
        _ = engine.registerKeystrokes("x", at: 0.3)
        let epochBefore = engine.epoch
        let outcome = engine.registerKeystrokes("\r", at: 0.4)
        #expect(outcome.invalidatedEpoch)
        #expect(engine.epoch > epochBefore)
        #expect(engine.overlay.cells.isEmpty)
        // Neutral: display confidence survives a submitted line.
        #expect(engine.overlay.displayState == .active)
    }

    @Test func controlSequenceInvalidatesEpochNeutrally() {
        var engine = activatedEngine()
        _ = engine.registerKeystrokes("x", at: 0.3)
        let outcome = engine.registerKeystrokes("\u{1B}[A", at: 0.4)
        #expect(outcome.invalidatedEpoch)
        #expect(engine.overlay.cells.isEmpty)
        #expect(engine.overlay.displayState == .active)
    }

    @Test func pasteBurstIsNeverPredicted() {
        var engine = baselineEngine()
        let paste = String(repeating: "a", count: 40)
        let outcome = engine.registerKeystrokes(paste, at: 0.1)
        #expect(outcome.predictedCellCount == 0)
        #expect(outcome.suppressed == [.pasteBurst])
        #expect(engine.overlay.cells.isEmpty)
    }

    @Test func pendingOverflowInvalidatesEpoch() {
        var engine = baselineEngine(
            configuration: .init(maximumPendingCells: 2)
        )
        let outcome = engine.registerKeystrokes("abc", at: 0.1)
        #expect(outcome.predictedCellCount == 2)
        #expect(outcome.suppressed == [.pendingOverflow])
        #expect(outcome.invalidatedEpoch)
        #expect(engine.overlay.cells.isEmpty)
    }

    // MARK: - Backspace

    @Test func backspaceRetractsOwnPredictions() {
        var engine = baselineEngine(cursor: (0, 4))
        _ = engine.registerKeystrokes("ab", at: 0.1)
        let first = engine.registerKeystrokes("\u{7F}", at: 0.2)
        #expect(first.retractedCellCount == 1)
        #expect(!first.invalidatedEpoch)
        #expect(engine.overlay.cells.count == 1)
        #expect(engine.overlay.predictedCursorColumn == 5)
        let second = engine.registerKeystrokes("\u{7F}", at: 0.3)
        #expect(second.retractedCellCount == 1)
        #expect(engine.overlay.cells.isEmpty)
        #expect(engine.overlay.predictedCursorColumn == 4)
    }

    @Test func backspaceOverForeignContentInvalidatesEpoch() {
        var engine = baselineEngine(cursor: (0, 4))
        let outcome = engine.registerKeystrokes("\u{7F}", at: 0.1)
        #expect(outcome.retractedCellCount == 0)
        #expect(outcome.invalidatedEpoch)
    }

    // MARK: - Confirmation and epoch invalidation

    @Test func matchingFrameConfirmsAndActivatesDisplay() {
        let engine = activatedEngine()
        #expect(engine.overlay.displayState == .active)
        #expect(engine.overlay.cells.isEmpty)
    }

    @Test func earlyFrameCannotContradictUnacknowledgedInput() {
        var engine = baselineEngine()
        _ = engine.registerKeystrokes("a", at: 0.1)
        // The frame is newer than anything delivered but predates the echo;
        // without an acknowledgment floor it must not mispredict.
        let outcome = engine.reconcile(
            update(seq: 100, cursor: (0, 0), rowTexts: [:]),
            at: 0.15
        )
        #expect(!outcome.mispredicted)
        #expect(engine.overlay.cells.count == 1)
    }

    @Test func matchConfirmsEvenBeforeAcknowledgment() {
        var engine = baselineEngine()
        _ = engine.registerKeystrokes("a", at: 0.1)
        let outcome = engine.reconcile(
            update(seq: 2, cursor: (0, 1), rowTexts: [0: "a"]),
            at: 0.15
        )
        #expect(outcome.confirmedCellCount == 1)
        #expect(engine.overlay.cells.isEmpty)
    }

    @Test func qualifiedContradictionInvalidatesWholeEpoch() {
        var engine = baselineEngine()
        _ = engine.registerKeystrokes("ab", at: 0.1)
        engine.acknowledgeInput(untilSeq: 10)

        // Below the acknowledgment floor: still waiting.
        let early = engine.reconcile(
            update(seq: 9, cursor: (0, 0), rowTexts: [0: "zz"]),
            at: 0.15
        )
        #expect(!early.mispredicted)
        #expect(engine.overlay.cells.count == 2)

        // At the floor with contradicting content: the whole epoch dies.
        let epochBefore = engine.epoch
        let qualified = engine.reconcile(
            update(seq: 10, cursor: (0, 2), rowTexts: [0: "zz"]),
            at: 0.2
        )
        #expect(qualified.mispredicted)
        #expect(engine.overlay.cells.isEmpty)
        #expect(engine.epoch > epochBefore)
        #expect(engine.overlay.displayState == .tentative)
    }

    @Test func mispredictCooldownBlocksReactivationUntilElapsed() {
        var engine = activatedEngine()
        _ = engine.registerKeystrokes("x", at: 1.0)
        engine.acknowledgeInput(untilSeq: 20)
        let mispredict = engine.reconcile(
            update(seq: 20, cursor: (0, 2), rowTexts: [0: "zz"]),
            at: 1.05
        )
        #expect(mispredict.mispredicted)
        #expect(engine.overlay.displayState == .tentative)

        // Two confirms inside the cooldown window keep the overlay hidden.
        _ = engine.registerKeystrokes("a", at: 1.1)
        _ = engine.reconcile(update(seq: 21, cursor: (0, 3), rowTexts: [0: "zza"]), at: 1.15)
        _ = engine.registerKeystrokes("b", at: 1.2)
        _ = engine.reconcile(update(seq: 22, cursor: (0, 4), rowTexts: [0: "zzab"]), at: 1.25)
        #expect(engine.overlay.displayState == .tentative)

        // The same streak after the cooldown elapses re-activates.
        _ = engine.registerKeystrokes("c", at: 2.0)
        _ = engine.reconcile(update(seq: 23, cursor: (0, 5), rowTexts: [0: "zzabc"]), at: 2.05)
        _ = engine.registerKeystrokes("d", at: 2.1)
        _ = engine.reconcile(update(seq: 24, cursor: (0, 6), rowTexts: [0: "zzabcd"]), at: 2.15)
        #expect(engine.overlay.displayState == .active)
    }

    @Test func repeatedMispredictsDoubleTheCooldown() {
        var engine = baselineEngine(
            configuration: .init(cooldownBase: 1.0, cooldownMax: 60.0, activationConfirmStreak: 1)
        )

        func mispredict(at time: TimeInterval, seq: UInt64) {
            _ = engine.registerKeystrokes("x", at: time)
            engine.acknowledgeInput(untilSeq: seq)
            let outcome = engine.reconcile(
                update(seq: seq, cursor: (0, 0), rowTexts: [0: "z"]),
                at: time
            )
            #expect(outcome.mispredicted)
        }
        func confirm(at time: TimeInterval, seq: UInt64) {
            _ = engine.registerKeystrokes("a", at: time)
            // A row of "a" confirms the prediction at whatever column the
            // cursor had reached.
            let outcome = engine.reconcile(
                update(seq: seq, cursor: (0, 1), rowTexts: [0: String(repeating: "a", count: 40)]),
                at: time
            )
            #expect(outcome.confirmedCellCount == 1)
        }

        mispredict(at: 0, seq: 10)
        // First cooldown is 1s: a confirm at 0.5s cannot re-activate...
        confirm(at: 0.5, seq: 11)
        #expect(engine.overlay.displayState == .tentative)
        // ...but one after 1s can.
        confirm(at: 1.5, seq: 12)
        #expect(engine.overlay.displayState == .active)

        mispredict(at: 2.0, seq: 20)
        mispredict(at: 2.1, seq: 21)
        // Two consecutive mispredicts: cooldown doubled to 2s from t=2.1.
        confirm(at: 3.5, seq: 22)
        #expect(engine.overlay.displayState == .tentative)
        confirm(at: 4.2, seq: 23)
        #expect(engine.overlay.displayState == .active)
    }

    // MARK: - No-echo detection

    @Test func unechoedPredictionExpiresAndHidesDisplay() {
        var engine = activatedEngine()
        _ = engine.registerKeystrokes("p", at: 1.0)
        let changed = engine.expireOverduePredictions(at: 1.7)
        #expect(changed)
        #expect(engine.overlay.cells.isEmpty)
        #expect(engine.overlay.displayState == .tentative)
    }

    @Test func noEchoContextKeepsTrackingSilentlyAndRearmsOnEcho() {
        var engine = activatedEngine()
        // Password prompt: predictions expire unconfirmed.
        _ = engine.registerKeystrokes("s", at: 1.0)
        _ = engine.expireOverduePredictions(at: 1.7)
        #expect(engine.overlay.displayState == .tentative)

        // Later keystrokes keep being tracked, silently.
        let silent = engine.registerKeystrokes("e", at: 2.0)
        #expect(silent.predictedCellCount == 1)
        #expect(!engine.overlay.isVisible)
        _ = engine.expireOverduePredictions(at: 2.7)

        // Echo returns: two confirmed predictions re-arm the overlay.
        _ = engine.registerKeystrokes("a", at: 3.0)
        _ = engine.reconcile(update(seq: 30, cursor: (0, 3), rowTexts: [0: "lsa"]), at: 3.05)
        _ = engine.registerKeystrokes("b", at: 3.1)
        _ = engine.reconcile(update(seq: 31, cursor: (0, 4), rowTexts: [0: "lsab"]), at: 3.15)
        #expect(engine.overlay.displayState == .active)
        _ = engine.registerKeystrokes("c", at: 3.2)
        #expect(engine.overlay.isVisible)
    }

    @Test func registeringKeystrokesExpiresStalePredictionsFirst() {
        var engine = baselineEngine()
        _ = engine.registerKeystrokes("p", at: 0)
        let outcome = engine.registerKeystrokes("q", at: 1.0)
        // The stale "p" epoch expired; "q" was predicted into a fresh epoch.
        #expect(outcome.predictedCellCount == 1)
        #expect(engine.overlay.cells.count == 1)
        #expect(engine.overlay.cells.first?.character == "q")
    }

    // MARK: - Scroll and coverage

    @Test func scrolledDeltaShiftsPendingRows() {
        var engine = baselineEngine(cursor: (5, 0))
        _ = engine.registerKeystrokes("a", at: 0.1)
        engine.acknowledgeInput(untilSeq: 10)
        let outcome = engine.reconcile(
            update(
                seq: 10,
                full: false,
                cursor: (3, 1),
                modesAuthoritative: false,
                scrolledRows: 2,
                rowTexts: [3: "a"]
            ),
            at: 0.15
        )
        #expect(outcome.confirmedCellCount == 1)
        #expect(!outcome.mispredicted)
    }

    @Test func predictionScrolledOffTheScreenDropsNeutrally() {
        var engine = baselineEngine(cursor: (1, 0))
        _ = engine.registerKeystrokes("a", at: 0.1)
        let outcome = engine.reconcile(
            update(
                seq: 10,
                full: false,
                cursor: (0, 0),
                modesAuthoritative: false,
                scrolledRows: 5,
                rowTexts: [10: "noise"]
            ),
            at: 0.15
        )
        #expect(!outcome.mispredicted)
        #expect(engine.overlay.cells.isEmpty)
    }

    @Test func deltaCoveringOtherRowsLeavesPredictionPending() {
        var engine = baselineEngine()
        _ = engine.registerKeystrokes("a", at: 0.1)
        engine.acknowledgeInput(untilSeq: 10)
        let outcome = engine.reconcile(
            update(
                seq: 10,
                full: false,
                cursor: nil,
                modesAuthoritative: false,
                rowTexts: [7: "unrelated"]
            ),
            at: 0.15
        )
        #expect(!outcome.mispredicted)
        #expect(outcome.confirmedCellCount == 0)
        #expect(engine.overlay.cells.count == 1)
    }

    @Test func nonColumnAddressableRowInvalidatesNeutrally() {
        var engine = baselineEngine()
        _ = engine.registerKeystrokes("a", at: 0.1)
        engine.acknowledgeInput(untilSeq: 10)
        let outcome = engine.reconcile(
            update(seq: 10, cursor: (0, 3), rowTexts: [0: "日本"]),
            at: 0.15
        )
        // Wide glyphs break column arithmetic: unjudgeable, but not a penalty.
        #expect(!outcome.mispredicted)
        #expect(engine.overlay.cells.isEmpty)
        #expect(engine.overlay.displayState == .tentative)
    }

    // MARK: - Cursor reconciliation

    @Test func qualifiedCursorContradictionMispredicts() {
        var engine = baselineEngine()
        _ = engine.registerKeystrokes("a", at: 0.1)
        engine.acknowledgeInput(untilSeq: 10)
        // Content matches (cell confirms) but the cursor landed elsewhere:
        // the application redrew the line, so the model is wrong.
        let outcome = engine.reconcile(
            update(seq: 10, cursor: (5, 0), rowTexts: [0: "a"]),
            at: 0.15
        )
        #expect(outcome.confirmedCellCount == 1)
        #expect(outcome.mispredicted)
        #expect(engine.overlay.displayState == .tentative)
    }

    @Test func matchingCursorSettlesBackToAuthoritative() {
        var engine = baselineEngine()
        _ = engine.registerKeystrokes("a", at: 0.1)
        engine.acknowledgeInput(untilSeq: 10)
        let outcome = engine.reconcile(
            update(seq: 10, cursor: (0, 1), rowTexts: [0: "a"]),
            at: 0.15
        )
        #expect(outcome.confirmedCellCount == 1)
        #expect(!outcome.mispredicted)
        #expect(engine.overlay.predictedCursorRow == nil)
        // The next keystroke predicts from the authoritative cursor.
        _ = engine.registerKeystrokes("b", at: 0.2)
        #expect(
            engine.overlay.cells
                == [MobileEchoPredictionOverlay.Cell(row: 0, column: 1, character: "b")]
        )
    }

    @Test func unacknowledgedCursorIsNeverJudged() {
        var engine = baselineEngine()
        _ = engine.registerKeystrokes("a", at: 0.1)
        // Early frame confirms by content match before any acknowledgment.
        var outcome = engine.reconcile(
            update(seq: 5, cursor: (0, 0), rowTexts: [0: "a"]),
            at: 0.12
        )
        #expect(outcome.confirmedCellCount == 1)
        // The authoritative cursor still shows the pre-echo position, but the
        // input has no acknowledgment floor, so this must not mispredict.
        #expect(!outcome.mispredicted)

        engine.acknowledgeInput(untilSeq: 9)
        outcome = engine.reconcile(update(seq: 9, cursor: (0, 1)), at: 0.2)
        #expect(!outcome.mispredicted)
        #expect(engine.overlay.predictedCursorRow == nil)
    }

    // MARK: - Stream reset

    @Test func streamResetDropsEverythingIncludingBaseline() {
        var engine = activatedEngine()
        _ = engine.registerKeystrokes("x", at: 0.3)
        engine.invalidateForStreamReset()
        #expect(engine.overlay.cells.isEmpty)
        #expect(engine.overlay.displayState == .tentative)
        let outcome = engine.registerKeystrokes("a", at: 0.4)
        #expect(outcome.suppressed == [.noBaseline])
    }

    // MARK: - Frame adapter

    @Test func fullFrameAdapterSummarizesModesAndCoverage() throws {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "s1",
            stateSeq: 42,
            columns: 20,
            rows: 4,
            cursor: .init(row: 1, column: 3, visible: false),
            full: true,
            styles: [.default],
            rowSpans: [
                .init(row: 0, column: 0, styleID: 0, text: "prompt>"),
                .init(row: 1, column: 2, styleID: 0, text: "ok"),
            ],
            activeScreen: .primary,
            modes: [.init(code: 1002, ansi: false, on: true)]
        )
        let summary = MobileEchoAuthoritativeUpdate(frame: frame)
        #expect(summary.stateSeq == 42)
        #expect(summary.isFull)
        #expect(summary.modesAuthoritative)
        #expect(summary.mouseTrackingActive)
        #expect(summary.cursorRow == 1)
        #expect(summary.cursorColumn == 3)
        #expect(!summary.cursorVisible)
        #expect(summary.coveredRows == Set(0..<4))
        #expect(summary.character(atRow: 0, column: 0) == "p")
        #expect(summary.character(atRow: 1, column: 2) == "o")
        // Column padding: span starts at column 2, columns 0-1 are blank.
        #expect(summary.character(atRow: 1, column: 0) == " ")
        // Uncovered would be nil; row 3 is covered (full frame) and blank.
        #expect(summary.character(atRow: 3, column: 5) == " ")
    }

    @Test func deltaFrameAdapterCoversOnlyStatedRows() throws {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "s1",
            stateSeq: 43,
            columns: 20,
            rows: 4,
            cursor: nil,
            full: false,
            clearedRows: [2],
            styles: [.default],
            rowSpans: [.init(row: 1, column: 0, styleID: 0, text: "hi")],
            activeScreen: .primary,
            modes: []
        )
        let summary = MobileEchoAuthoritativeUpdate(frame: frame)
        #expect(!summary.isFull)
        #expect(!summary.modesAuthoritative)
        #expect(summary.cursorRow == nil)
        #expect(summary.coveredRows == [1, 2])
        #expect(summary.character(atRow: 1, column: 1) == "i")
        #expect(summary.character(atRow: 2, column: 0) == " ")
        #expect(summary.character(atRow: 0, column: 0) == nil)
    }

    @Test func adapterMarksWideRowsUnaddressable() {
        let summary = update(seq: 1, rowTexts: [0: "日本", 1: "ascii"])
        #expect(!summary.rowIsColumnAddressable(0))
        #expect(summary.rowIsColumnAddressable(1))
        #expect(summary.rowIsColumnAddressable(2))
    }
}
