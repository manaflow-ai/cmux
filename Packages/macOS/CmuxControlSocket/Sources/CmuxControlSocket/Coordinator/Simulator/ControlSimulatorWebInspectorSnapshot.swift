public import Foundation

/// The current Web Inspector targets and session state for one Simulator surface.
public struct ControlSimulatorWebInspectorSnapshot: Sendable, Equatable {
    /// The Simulator surface that produced the snapshot.
    public let surfaceID: UUID
    /// The inspectable WebKit targets reported by the worker.
    public let targets: [ControlSimulatorWebInspectorTargetSnapshot]
    /// The worker's current Web Inspector attachment state.
    public let session: ControlSimulatorWebInspectorSessionSnapshot
    /// Whether element highlighting is enabled.
    public let isHighlighted: Bool

    /// Creates an immutable Web Inspector state snapshot.
    public init(
        surfaceID: UUID,
        targets: [ControlSimulatorWebInspectorTargetSnapshot],
        session: ControlSimulatorWebInspectorSessionSnapshot,
        isHighlighted: Bool
    ) {
        self.surfaceID = surfaceID
        self.targets = targets
        self.session = session
        self.isHighlighted = isHighlighted
    }
}
