import Foundation

extension AgentPaneModel {
    /// Asks acpmux for the portable document, then reuses the existing native
    /// save panel. The daemon does all transcript and event serialization.
    func exportChats(keys: [String], all: Bool, format: String) async -> [String: Any] {
        guard let socketPath = transport.acpmuxSocket ?? transport.socketPath else {
            return AgentPaneReply.failure(code: "unavailable", message: "Chat export is unavailable")
        }
        guard let onSaveFile else {
            return AgentPaneReply.failure(code: "unsupported", message: "Saving is unavailable")
        }
        do {
            var params: [String: any Sendable] = ["all": all, "format": format]
            if !keys.isEmpty { params["keys"] = keys }
            let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/chat_export", params: params, deadline: nil)
            guard let text = result["content"] as? String, !text.isEmpty else {
                return AgentPaneReply.failure(code: "export_failed", message: "The daemon returned no export")
            }
            let kind: AgentPaneSave.Kind = format == "markdown" ? .markdown : .json
            let save = AgentPaneSave(text: text, suggestedName: all ? "chats" : "chat", kind: kind)!
            return AgentPaneReply.success(try await onSaveFile(save))
        } catch {
            return AgentPaneReply.failure(code: "export_failed", message: error.localizedDescription)
        }
    }
}
