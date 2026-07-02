import Foundation

/// A render-ready snapshot for one row in the pairing checklist.
public struct MobilePairingStepSnapshot: Equatable, Identifiable, Sendable {
    /// The stable row identity.
    public var id: MobilePairingStep { step }
    /// The pairing gate this row represents.
    public var step: MobilePairingStep
    /// The current state of the gate.
    public var status: MobilePairingStepStatus
    /// The failure headline for this gate, when ``status`` is ``MobilePairingStepStatus/failed``.
    public var message: String?
    /// The shorter recovery suggestion for this gate, when one is available.
    public var guidance: String?

    /// Creates a pairing-check row snapshot.
    ///
    /// - Parameters:
    ///   - step: The pairing gate this row represents.
    ///   - status: The current state of the gate.
    ///   - message: The failure headline for this gate.
    ///   - guidance: The shorter recovery suggestion for this gate.
    public init(
        step: MobilePairingStep,
        status: MobilePairingStepStatus,
        message: String? = nil,
        guidance: String? = nil
    ) {
        self.step = step
        self.status = status
        self.message = message
        self.guidance = guidance
    }
}
