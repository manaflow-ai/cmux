/// The server's fixed-size response to a control-stream admission proof.
public enum CmxIrohAdmissionDecision: Equatable, Sendable {
    /// The connection may create authenticated application lanes.
    case accepted

    /// Admission failed with a non-sensitive protocol code.
    case denied(code: UInt16)
}
