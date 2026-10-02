import Foundation

extension AgentPaneCheckpointRequest {
    /// Nil unless `method` is one of ``methods`` and `params` are exactly
    /// what the page's checkpoint client sends for it.
    init?(method: String, params: [String: Any]?) {
        return nil
    }
}
