import Foundation

extension AgentPaneModel {
    /// Opens a checked file through the pane host.
    func openFile(_ path: String, target: AgentPaneFileTarget) async -> [String: Any] {
        guard let onOpenFile else {
            return AgentPaneReply.failure(code: "open_failed", message: Self.openFileFailedMessage)
        }
        let url: URL
        switch checkedFileOpen(path, target: target) {
        case .success(let checked): url = checked
        case .failure(let refusal): return Self.transportFailure(refusal)
        }
        guard await onOpenFile(url, target) else {
            return AgentPaneReply.failure(code: "open_failed", message: Self.openFileFailedMessage)
        }
        return AgentPaneReply.success()
    }

    /// Preserves save cancellation as a successful false reply for the page.
    func saveLog(_ text: String, suggestedName: String) async -> [String: Any] {
        // The page copies the log instead on any failure, so these messages
        // are diagnostics, like the unsupported one below.
        guard let onSaveLog else { return AgentPaneReply.failure(code: "unsupported", message: "Saving the log is unavailable") }
        do {
            return AgentPaneReply.success(try await onSaveLog(text, suggestedName))
        } catch {
            return AgentPaneReply.failure(code: "save_failed", message: "Could not save the log: \(error.localizedDescription)")
        }
    }
}
