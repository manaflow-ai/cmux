import Foundation

/// `ConversationTabRef` and `AgentSessionRef` are generated from the schema's
/// `ConversationTabRecord` and `AgentSessionSource` (swift_app/bindings.json, Tree family).
extension AgentSessionRef {
    /// The `host` of this installation's install id.
    public static func host(installID: String) -> String { "install:" + installID }
}
