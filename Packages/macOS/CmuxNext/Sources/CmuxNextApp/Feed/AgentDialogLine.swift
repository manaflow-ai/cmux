import CmuxNextAgentPane
import Foundation

/// One short connection to this app's acpmux that ``AgentDialogDesk`` reads and answers on. The
/// app's is ``AcpmuxPersonLine`` (proven as the person); tests pass a fake.
@MainActor
protocol AgentDialogLine: AnyObject {
    /// acpmux took this connection's person proof.
    var isPerson: Bool { get }
    /// One request; its `result`, or nil when it failed or the connection closed.
    func call(_ method: String, _ params: [String: Any]) async -> [String: Any]?
    func close()
}

extension AcpmuxPersonLine: AgentDialogLine {}
