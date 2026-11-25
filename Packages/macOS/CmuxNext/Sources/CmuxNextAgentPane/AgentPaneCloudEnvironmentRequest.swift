public import CmuxNextDaemon
import Foundation

/// A forwarding envelope only: Rust decodes the page's message (``AgentPaneRequest/rustHostOp(method:params:)``);
/// the shared web editor and Rust's Cloud client check the fields.
public nonisolated struct AgentPaneCloudEnvironmentRequest: Equatable, Sendable {
    public let action: String
    public let params: JSONValue

    init(action: String, params: JSONValue) {
        self.action = action
        self.params = params
    }
}
