/// Failures returned by Pane Rack terminal mutation intents.
public enum PaneRackMutationFailure: Error, Equatable, Sendable {
    /// The owning Mac does not support the requested mutation.
    case unsupported
    /// The owning Mac is not connected.
    case notConnected
    /// The requested workspace, pane, or terminal is not present locally.
    case invalidTarget
    /// The Mac refused to close the workspace's last terminal.
    case lastTerminal(message: String)
    /// The Mac or transport rejected the mutation.
    case rejected(message: String)
}
