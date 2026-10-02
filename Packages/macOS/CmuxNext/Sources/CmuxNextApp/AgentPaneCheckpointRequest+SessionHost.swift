import CmuxNextAgentPane
import CmuxNextDaemon

extension AgentPaneCheckpointRequest {
    /// The session host's params.
    var sessionHostParams: [String: JSONValue] {
        ["path": .string(cwd)]
    }
}
