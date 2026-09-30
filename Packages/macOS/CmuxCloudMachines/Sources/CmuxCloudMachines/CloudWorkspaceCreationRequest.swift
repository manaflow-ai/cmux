import Foundation

/// An existing-machine creation intent bound to its account and originating window.
public struct CloudWorkspaceCreationRequest: Hashable, Sendable {
    /// The machine on which to create a new workspace.
    public let machineID: String
    /// The authenticated scope captured before loading or creating remotely.
    public let scopeID: String
    /// The window that will own the local projection, regardless of later focus changes.
    public let windowID: UUID

    /// Captures the complete creation destination.
    /// - Parameters:
    ///   - machineID: The existing Cloud machine identity.
    ///   - scopeID: The authenticated account/team identity.
    ///   - windowID: The originating window identity.
    public init(machineID: String, scopeID: String, windowID: UUID) {
        self.machineID = machineID
        self.scopeID = scopeID
        self.windowID = windowID
    }
}
