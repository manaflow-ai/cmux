import Foundation

/// The execution and presentation identities owned by one explicit machine create.
public struct CloudMachineCreateRequest: Equatable, Sendable {
    /// The unchanged CLI arguments reused by retries, including the idempotency scope.
    public let arguments: [String]
    /// Whether this opens an existing Base slot instead of allocating a new machine.
    public let isBaseSetup: Bool
    /// The local reservation to release when the user abandons this create.
    public let presentationWorkspaceID: UUID?
    /// Whether success waits for authoritative projection before retiring the pending row.
    public let retainsPendingProjection: Bool

    /// Describes a create without depending on app models or localized presentation.
    ///
    /// - Parameters:
    ///   - arguments: Exact invocation to reuse on retry.
    ///   - isBaseSetup: Existing Base slots must never be destroyed by cancellation.
    ///   - presentationWorkspaceID: Workspace reserved before launching, if any.
    ///   - retainsPendingProjection: Keeps a successful reservation until fleet adoption.
    public init(arguments: [String], isBaseSetup: Bool, presentationWorkspaceID: UUID?, retainsPendingProjection: Bool) {
        self.arguments = arguments
        self.isBaseSetup = isBaseSetup
        self.presentationWorkspaceID = presentationWorkspaceID
        self.retainsPendingProjection = retainsPendingProjection
    }
}
