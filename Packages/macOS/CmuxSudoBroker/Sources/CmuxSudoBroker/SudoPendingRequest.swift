/// A request paired with the exact script content shown to the approver.
public struct SudoPendingRequest: Sendable, Equatable {
    /// The request metadata.
    public let request: SudoRequest

    /// The immutable script snapshot displayed during approval.
    public let script: String

    /// The durable phase observed when the snapshot was discovered.
    public let phase: SudoRequestPhase

    /// Creates a pending request snapshot.
    ///
    /// - Parameters:
    ///   - request: The request metadata captured by the CLI.
    ///   - script: The exact immutable script shown during approval.
    ///   - phase: The durable lifecycle phase, defaulting to pending approval.
    public init(
        request: SudoRequest,
        script: String,
        phase: SudoRequestPhase = .pendingApproval
    ) {
        self.request = request
        self.script = script
        self.phase = phase
    }
}
