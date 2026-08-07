/// A request paired with the exact script content shown to the approver.
public struct SudoPendingRequest: Sendable, Equatable {
    /// The request metadata.
    public let request: SudoRequest

    /// The immutable script snapshot displayed during approval.
    public let script: String

    /// Creates a pending request snapshot.
    public init(request: SudoRequest, script: String) {
        self.request = request
        self.script = script
    }
}

