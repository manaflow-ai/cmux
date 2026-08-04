/// Failures that can prevent a prepared semantic snapshot from being committed.
package enum SimulatorUIAutomationSnapshotRecordingError: Error, Equatable, Sendable {
    /// Pane input changed while the immutable snapshot was prepared off the main actor.
    case invalidatedDuringPreparation
}
