import CmuxSimulator
import Foundation

/// Reference and snapshot lookup failures for one pane-owned UI session.
public enum SimulatorUIAutomationReferenceError: Error, Equatable, Sendable {
    /// No snapshot has been captured in the pane session.
    case snapshotMissing
    /// The current snapshot exceeded its bounded reference lifetime.
    case snapshotExpired(ageMilliseconds: Int64)
    /// The supplied element reference is absent from the current snapshot.
    case elementRefNotFound(String)
    /// The target does not advertise any of the required actions.
    case targetNotActionable(
        ref: String,
        required: [SimulatorUIAutomationActionName]
    )
    /// The target has no stable semantic fields suitable for a refreshed wait.
    case stableSelectorUnavailable(String)
}
