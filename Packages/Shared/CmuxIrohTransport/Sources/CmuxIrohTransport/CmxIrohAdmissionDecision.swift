/// The server's initial response to a control-stream admission proof.
public enum CmxIrohAdmissionDecision: Equatable, Sendable {
    /// The proof passed, but application lanes await the NAT authorization barrier.
    case accepted

    /// Admission failed with a non-sensitive protocol code.
    case denied(code: UInt16)
}
