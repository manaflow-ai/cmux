import Foundation

extension SimulatorAccessibilitySnapshot {
    /// Builds a compact ref-bearing automation snapshot from the native tree.
    ///
    /// - Parameters:
    ///   - simulatorID: The selected CoreSimulator device identifier.
    ///   - refNamespace: The pane-session identity embedded in every element ref.
    ///   - sequence: The pane-local snapshot sequence.
    ///   - capturedAtMilliseconds: The capture time in Unix epoch milliseconds.
    /// - Returns: The public snapshot and its process-local lookup metadata.
    /// - Throws: ``SimulatorUIAutomationSnapshotError/viewportUnavailable`` when no root has
    ///   a usable viewport.
    public func uiAutomationRecord(
        simulatorID: String,
        refNamespace: UUID = UUID(),
        sequence: UInt64,
        capturedAtMilliseconds: Int64
    ) throws -> SimulatorUIAutomationSnapshotRecord {
        try SimulatorUIAutomationSnapshotBuilder(
            source: self,
            simulatorID: simulatorID,
            refNamespace: refNamespace,
            sequence: sequence,
            capturedAtMilliseconds: capturedAtMilliseconds
        ).build()
    }
}
