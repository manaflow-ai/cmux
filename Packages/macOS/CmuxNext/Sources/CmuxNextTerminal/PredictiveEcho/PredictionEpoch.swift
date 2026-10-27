/// Runs of echo predictions that show only after the host echoed one of them: mosh's
/// `prediction_epoch` / `confirmed_epoch` (src/frontend/terminaloverlay.cc). Anything the engine
/// cannot predict starts a new epoch (mosh `become_tentative`), so the first keystroke after it
/// stays hidden until its own echo matches, while predictions of an already confirmed epoch keep
/// showing. A password prompt that turns echo off therefore never shows a predicted glyph.
nonisolated struct PredictionEpoch: Equatable, Sendable {
    /// The epoch new predictions join; grows by one per epoch.
    private(set) var id: UInt64 = 1
    /// The newest epoch one of whose predictions matched a real echo that changed a cell.
    private(set) var confirmedID: UInt64 = 0

    /// True once the epoch new predictions join is confirmed.
    var isConfirmed: Bool { confirmedID >= id }

    /// Whether predictions of `epoch` show.
    func hasConfirmed(_ epoch: UInt64) -> Bool {
        epoch <= confirmedID
    }

    /// Starts a new, unconfirmed epoch for later predictions.
    mutating func advance() {
        id &+= 1
    }

    /// A prediction of `epoch` matched its echo.
    mutating func confirm(_ epoch: UInt64) {
        confirmedID = max(confirmedID, epoch)
    }
}
