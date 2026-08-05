public import CmuxAgentWire

/// Errors thrown by ``AgentSyncEngine`` before or after transport calls.
public enum AgentSyncError: Error, Hashable, Sendable {
    /// The requested operation requires a connected engine.
    case offline
    /// The requested conversation is not open.
    case conversationNotOpen
    /// The RPC returned a malformed payload.
    case malformedResponse
    /// The transport failed with a GUI wire error.
    case wire(GuiWireError)
    /// The transport failed with an unclassified error.
    case transport(String)
}
