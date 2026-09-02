import Foundation

/// The command target attached to a queued checklist item.
public struct WorkspaceTaskDispatchTarget: Codable, Sendable, Hashable {
    /// The directory in which the new agent workspace starts, when supplied.
    public var workingDirectory: String?
    /// The command sent to the new workspace after creation.
    public var agentCommand: String
    /// A display/provider name for the owning agent, when known.
    public var agentName: String?

    /// Creates a dispatch target.
    public init(
        workingDirectory: String? = nil,
        agentCommand: String,
        agentName: String? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.agentCommand = agentCommand
        self.agentName = agentName
    }
}
