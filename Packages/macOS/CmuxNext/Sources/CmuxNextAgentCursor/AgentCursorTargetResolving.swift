public import CmuxNextAgentCursorVisibility

/// Answers where a target is. The stand-in for the visibility resolver
/// (owner a9: a pure resolver with vectors); the App supplies the live one.
@MainActor
public protocol AgentCursorTargetResolving: AnyObject {
    func placement(forTarget targetID: String) -> AgentCursorPlacement
}
