extension MobileTerminalRenderGridFrame {
    /// Upper bound on history rows a screen-anchored burst delta may carry.
    /// Bursts larger than this leave a gap in the consumer's scrollback (the
    /// oldest missed rows), matching a terminal that was detached during the
    /// flood; the visible grid stays exact either way.
    public static let maxBurstScrollbackRows = 2000

    /// History rows a screen-anchored consumer hydrates at attach, and that
    /// full re-emissions carry so a mid-stream replay reset (theme change,
    /// resize, resync) preserves the consumer's deep local scrollback.
    public static let screenAnchorScrollbackRowBudget = 4000

    /// Cached producer state for this frame.
    ///
    /// Producers keep this compact value after emitting a frame, then pass it to
    /// ``renderGridEmission(comparedTo:fullScrollbackTarget:)`` for the next
    /// full producer snapshot.
    public var emissionState: MobileTerminalRenderGridEmissionState {
        MobileTerminalRenderGridEmissionState(
            renderEpoch: renderEpoch,
            columns: columns,
            rows: rows,
            stateSeq: stateSeq,
            activeScreen: activeScreen,
            terminalTheme: terminalTheme,
            terminalConfigTheme: terminalConfigTheme,
            rowSignatures: rowSignatures(),
            anchor: anchor,
            historyRows: historyRows,
            rowSpaceRevision: rowSpaceRevision
        )
    }

    /// The decision for one producer snapshot compared with the prior state.
    public enum Emission: Equatable, Sendable {
        /// Emit `frame` and cache `state` for the next comparison.
        case emit(frame: MobileTerminalRenderGridFrame, state: MobileTerminalRenderGridEmissionState)
        /// The snapshot needs a re-export carrying `scrollbackRows` history
        /// rows before it can be emitted: either a screen-anchored burst
        /// (more rows scrolled than the grid holds, so the delta must carry
        /// the missed rows) or a full frame that must preserve the consumer's
        /// deep local scrollback through the replay reset.
        case needsScrollback(rows: Int)
        /// The snapshot is unchanged; emit nothing.
        case none

        /// The emitted frame/state pair, or `nil` for ``none`` and
        /// ``needsScrollback(rows:)``.
        public var emitted: (
            frame: MobileTerminalRenderGridFrame,
            state: MobileTerminalRenderGridEmissionState
        )? {
            if case .emit(let frame, let state) = self { return (frame, state) }
            return nil
        }
    }

    /// Selects the event frame to emit compared with a previous producer state.
    ///
    /// The returned frame is `self` for first frames, shape changes, and changed
    /// frames that must stay full because DEC origin mode is active. Otherwise it
    /// is a row delta, or ``Emission/none`` when the producer snapshot is
    /// unchanged. Screen-anchored (v2) comparisons additionally turn history
    /// growth into ``scrolledRows`` so the consumer's local scrollback
    /// accumulates: row signatures are compared after shifting the previous
    /// grid up by the scrolled amount.
    ///
    /// - Parameters:
    ///   - previous: The compact state from the last emitted snapshot, or `nil`
    ///     when no prior frame was emitted for the surface.
    ///   - fullScrollbackTarget: History rows a FULL emission should carry
    ///     (screen-anchored consumers rebuild their local scrollback from full
    ///     replays; `0` keeps the v1 behavior of scrollback-free event fulls).
    ///   - allowScrollbackRequest: Pass `false` on the re-export retry so a
    ///     racing burst cannot request re-exports forever; the retry emits with
    ///     whatever scrollback the frame carries.
    /// - Throws: ``MobileTerminalRenderGridError`` if a generated delta would be invalid.
    public func renderGridEmission(
        comparedTo previous: MobileTerminalRenderGridEmissionState?,
        fullScrollbackTarget: Int = 0,
        allowScrollbackRequest: Bool = true
    ) throws -> Emission {
        let nextSignatures = rowSignatures()
        let nextState = MobileTerminalRenderGridEmissionState(
            renderEpoch: renderEpoch,
            columns: columns,
            rows: rows,
            stateSeq: stateSeq,
            activeScreen: activeScreen,
            terminalTheme: terminalTheme,
            terminalConfigTheme: terminalConfigTheme,
            rowSignatures: nextSignatures,
            anchor: anchor,
            historyRows: historyRows,
            rowSpaceRevision: rowSpaceRevision
        )
        func fullEmission() throws -> Emission {
            if allowScrollbackRequest,
               fullScrollbackTarget > 0,
               activeScreen == .primary,
               scrollbackRows < min(fullScrollbackTarget, Int(min(historyRows ?? 0, UInt64(Int.max)))) {
                return .needsScrollback(rows: fullScrollbackTarget)
            }
            return .emit(frame: self, state: nextState)
        }
        guard let previous,
              previous.renderEpoch == renderEpoch,
              previous.columns == columns,
              previous.rows == rows,
              previous.anchor == anchor else {
            return try fullEmission()
        }
        if previous.activeScreen != activeScreen {
            return try fullEmission()
        }
        if previous.terminalTheme != terminalTheme {
            return try fullEmission()
        }
        if previous.terminalConfigTheme != terminalConfigTheme {
            return try fullEmission()
        }

        // Screen-anchored comparison: turn history growth into an exact scroll
        // amount. The row-space revision guards the arithmetic: eviction,
        // reflow, and erase can shift retained rows to different offsets, and
        // the comparison then falls back to in-place repaints (scrolled = 0).
        let historyGrowth: Int = {
            guard anchor == .screen,
                  activeScreen == .primary,
                  let prevHistory = previous.historyRows,
                  let nowHistory = historyRows,
                  let prevRevision = previous.rowSpaceRevision,
                  let nowRevision = rowSpaceRevision,
                  prevRevision == nowRevision,
                  nowHistory > prevHistory else { return 0 }
            return Int(min(nowHistory - prevHistory, UInt64(Int.max)))
        }()

        if historyGrowth > rows {
            // Burst: more rows scrolled through than the grid holds, so the
            // delta must carry the missed history rows. Ask the caller to
            // re-export with them; on the retry, emit with what is carried.
            let missed = historyGrowth - rows
            let carried = min(scrollbackRows, missed)
            if allowScrollbackRequest, carried < min(missed, Self.maxBurstScrollbackRows) {
                return .needsScrollback(rows: min(missed, Self.maxBurstScrollbackRows))
            }
            let changedRows = Set((0..<rows).filter { !nextSignatures[$0].isEmpty })
            let deltaFrame = try filteredRows(
                changedRows,
                full: false,
                scrolledRows: rows + carried,
                carryScrollbackSpans: true,
                deltaBaseHistoryRows: previous.historyRows
            )
            return .emit(frame: deltaFrame, state: nextState)
        }

        let scrolled = historyGrowth
        var changedRows = Set<Int>()
        if scrolled > 0 {
            // Rows still on the grid after the shift: compare against the
            // previous frame shifted up by the scrolled amount. Rows that
            // scrolled in at the bottom are blank after the shift, so only
            // non-blank content needs a repaint.
            for index in 0..<(rows - scrolled)
            where previous.rowSignatures[index + scrolled] != nextSignatures[index] {
                changedRows.insert(index)
            }
            for index in (rows - scrolled)..<rows where !nextSignatures[index].isEmpty {
                changedRows.insert(index)
            }
        } else {
            let count = min(previous.rowSignatures.count, nextSignatures.count)
            for index in 0..<count where previous.rowSignatures[index] != nextSignatures[index] {
                changedRows.insert(index)
            }
        }

        if changedRows.isEmpty, scrolled == 0, previous.stateSeq == stateSeq {
            return .none
        }

        // Row repaints under DEC origin mode stay full snapshots, but a
        // cursor-only advance (no changed rows) does not need one: the delta
        // replay disables origin mode before its absolute cursor move, and a
        // full-screen app holding DECOM would otherwise promote every
        // keystroke tick into a full-grid payload.
        if !changedRows.isEmpty, modes.contains(where: { $0.isDECOriginMode && $0.on }) {
            return try fullEmission()
        }

        let deltaFrame = try filteredRows(
            changedRows,
            full: false,
            scrolledRows: scrolled,
            deltaBaseHistoryRows: anchor == .screen ? previous.historyRows : nil
        )
        return .emit(frame: deltaFrame, state: nextState)
    }
}
