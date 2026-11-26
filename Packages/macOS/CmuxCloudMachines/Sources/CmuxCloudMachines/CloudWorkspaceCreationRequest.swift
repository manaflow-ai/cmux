import Foundation

/// An existing-machine creation intent bound to its account and originating window.
public struct CloudWorkspaceCreationRequest: Hashable, Sendable {
    /// The machine on which to create a new workspace.
    public let machineID: String
    /// The authenticated scope captured before loading or creating remotely.
    public let scopeID: String
    /// The window that will own the local projection, regardless of later focus changes.
    public let windowID: UUID
    /// Navigation at dispatch; local admission may select only while it is current.
    public let selectionRevision: UInt64?

    /// Captures the complete creation destination.
    /// - Parameters:
    ///   - machineID: The existing Cloud machine identity.
    ///   - scopeID: The authenticated account/team identity.
    ///   - windowID: The originating window identity.
    ///   - selectionRevision: The originating window's navigation revision, before any await.
    public init(machineID: String, scopeID: String, windowID: UUID, selectionRevision: UInt64? = nil) {
        self.machineID = machineID
        self.scopeID = scopeID
        self.windowID = windowID
        self.selectionRevision = selectionRevision
    }
}
