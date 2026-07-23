import Foundation

/// A fresh Computer Use driver state associated with its surface-derived session.
struct ComputerUseWatchTargetActivity: Equatable, Sendable {
    let driverSessionID: String
    let state: ComputerUseDriverState

    var targetPID: Int { state.targetPID }
    var lastActionAt: Date { state.lastActionAt }
}
