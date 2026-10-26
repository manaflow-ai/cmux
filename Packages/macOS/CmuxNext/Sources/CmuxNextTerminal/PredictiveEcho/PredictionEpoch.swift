/// A run of echo predictions that shows only after the host echoed one of them: mosh's
/// `prediction_epoch` / `confirmed_epoch` (src/frontend/terminaloverlay.cc). Anything the engine
/// cannot predict starts a new epoch, so the first keystroke after it stays hidden until its own
/// echo matches. A password prompt that turns echo off therefore never shows a predicted glyph.
nonisolated struct PredictionEpoch: Equatable, Sendable {
    /// Grows by one per epoch; the overlay compares it to know its drawn cells are stale.
    private(set) var id: UInt64 = 1
    /// True once a prediction of this epoch matched a real echo that changed a cell.
    private(set) var isConfirmed = false

    /// Starts a new, unconfirmed epoch.
    mutating func advance() {
        id &+= 1
        isConfirmed = false
    }

    mutating func confirm() {
        isConfirmed = true
    }
}
