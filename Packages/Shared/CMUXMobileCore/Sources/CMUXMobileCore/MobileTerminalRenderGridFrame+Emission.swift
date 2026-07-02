public extension MobileTerminalRenderGridFrame {
    /// Cached producer state for this frame.
    ///
    /// Producers keep this compact value after emitting a frame, then pass it to
    /// ``renderGridEmission(comparedTo:)`` for the next full producer snapshot.
    var emissionState: MobileTerminalRenderGridEmissionState {
        MobileTerminalRenderGridEmissionState(
            columns: columns,
            rows: rows,
            stateSeq: stateSeq,
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
    func renderGridEmission(
        comparedTo previous: MobileTerminalRenderGridEmissionState?
    ) throws -> (frame: MobileTerminalRenderGridFrame, state: MobileTerminalRenderGridEmissionState)? {
        let nextSignatures = rowSignatures()
        let nextState = MobileTerminalRenderGridEmissionState(
            columns: columns,
            rows: rows,
            stateSeq: stateSeq,
            rowSignatures: nextSignatures
        )
        guard let previous,
              previous.columns == columns,
              previous.rows == rows else {
            return (self, nextState)
        }

        var changedRows = Set<Int>()
        let count = min(previous.rowSignatures.count, nextSignatures.count)
        for index in 0..<count where previous.rowSignatures[index] != nextSignatures[index] {
            changedRows.insert(index)
        }

        if changedRows.isEmpty, previous.stateSeq == stateSeq {
            return nil
        }

        if modes.contains(where: { $0.isDECOriginMode && $0.on }) {
            return (self, nextState)
        }

        let deltaFrame = try filteredRows(changedRows, full: false)
        return (deltaFrame, nextState)
    }
}
