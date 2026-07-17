extension MobileTerminalRenderGridFrame {
    /// Cached producer state for this frame.
    ///
    /// Producers keep this compact value after emitting a frame, then pass it to
    /// ``renderGridEmission(comparedTo:)`` for the next full producer snapshot.
    public var emissionState: MobileTerminalRenderGridEmissionState {
        MobileTerminalRenderGridEmissionState(
            columns: columns,
            rows: rows,
            stateSeq: stateSeq,
            producerEpoch: producerEpoch,
            activeScreen: activeScreen,
            cursor: cursor,
            defaultStyle: styles.first(where: { $0.id == 0 }),
            terminalForeground: terminalForeground,
            terminalBackground: terminalBackground,
            terminalCursorColor: terminalCursorColor,
            terminalCursorTextColor: terminalCursorTextColor,
            terminalTheme: terminalTheme,
            terminalConfigTheme: terminalConfigTheme,
            rowSignatures: rowSignatures()
        )
    }

    /// Selects the event frame to emit compared with a previous producer state.
    ///
    /// The returned frame is `self` for first frames, shape changes, and changed
    /// frames that must stay full because DEC origin mode is active. Otherwise it
    /// is a row delta, or `nil` when the producer snapshot is unchanged.
    ///
    /// - Parameter previous: The compact state from the last emitted snapshot, or
    ///   `nil` when no prior frame was emitted for the surface.
    /// - Returns: The frame to emit plus the compact state to cache for the next
    ///   comparison, or `nil` when no event should be emitted.
    /// - Throws: ``MobileTerminalRenderGridError`` if a generated delta would be invalid.
    public func renderGridEmission(
        comparedTo previous: MobileTerminalRenderGridEmissionState?
    ) throws -> (frame: MobileTerminalRenderGridFrame, state: MobileTerminalRenderGridEmissionState)? {
        let nextSignatures = rowSignatures()
        let nextState = MobileTerminalRenderGridEmissionState(
            columns: columns,
            rows: rows,
            stateSeq: stateSeq,
            producerEpoch: producerEpoch,
            activeScreen: activeScreen,
            cursor: cursor,
            defaultStyle: styles.first(where: { $0.id == 0 }),
            terminalForeground: terminalForeground,
            terminalBackground: terminalBackground,
            terminalCursorColor: terminalCursorColor,
            terminalCursorTextColor: terminalCursorTextColor,
            terminalTheme: terminalTheme,
            terminalConfigTheme: terminalConfigTheme,
            rowSignatures: nextSignatures
        )
        if let previous, previous.producerEpoch != producerEpoch {
            return (self, nextState)
        }
        guard let previous,
              previous.columns == columns,
              previous.rows == rows else {
            return (self, nextState)
        }
        if previous.activeScreen != activeScreen {
            return (self, nextState)
        }
        if previous.terminalTheme != terminalTheme {
            return (self, nextState)
        }
        if previous.terminalConfigTheme != terminalConfigTheme {
            return (self, nextState)
        }

        var changedRows = Set<Int>()
        let count = min(previous.rowSignatures.count, nextSignatures.count)
        for index in 0..<count where previous.rowSignatures[index] != nextSignatures[index] {
            changedRows.insert(index)
        }

        let cursorChanged = previous.cursor != cursor
            || previous.terminalCursorColor != terminalCursorColor
            || previous.terminalCursorTextColor != terminalCursorTextColor
        let defaultPaintChanged = previous.defaultStyle != nextState.defaultStyle
            || previous.terminalForeground != terminalForeground
            || previous.terminalBackground != terminalBackground

        if changedRows.isEmpty,
           previous.stateSeq == stateSeq,
           !cursorChanged,
           !defaultPaintChanged {
            return nil
        }

        // Empty cells are painted from the default style, so a default-color
        // change must remain a complete repaint even when no row span changed.
        if defaultPaintChanged {
            return (self, nextState)
        }

        // Row repaints under DEC origin mode stay full snapshots, but a
        // cursor-only advance (no changed rows) does not need one: the delta
        // replay disables origin mode before its absolute cursor move, and a
        // full-screen app holding DECOM would otherwise promote every
        // keystroke tick into a full-grid payload.
        if !changedRows.isEmpty, modes.contains(where: { $0.isDECOriginMode && $0.on }) {
            return (self, nextState)
        }

        let deltaFrame = try filteredRows(changedRows, full: false)
        return (deltaFrame, nextState)
    }
}
