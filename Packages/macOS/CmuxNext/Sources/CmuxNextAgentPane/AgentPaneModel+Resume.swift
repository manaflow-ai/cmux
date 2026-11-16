extension AgentPaneModel {
    /// `/resume <ref>` in the composer (`chats.resume`; Lawrence 2026-11-07: "i paste in
    /// 920ab030-… and i want it to 'just work'"). This Mac's acpmux finds the chat the pasted session
    /// id, id start, transcript path or resume command names in its device index (any project
    /// folder, Claude Code or Codex; `_acpmux/chat_resolve`), and it opens through the app's shared
    /// Open Chat path (``onOpenChat``): a new workspace in the chat's own folder, or the tab that
    /// already shows it. A chat of another machine's pane asks no index of that machine.
    func resumeChat(_ ref: String) async -> ChatResumeStatus {
        guard !remoteChat, let onOpenChat, let socketPath = transport.acpmuxSocket ?? transport.socketPath else { return .unavailable }
        let resolved: Result<String, ChatResumeStatus>
        do {
            resolved = try await AcpmuxStatusClient.chatResolve(socketPath: socketPath, ref: ref)
        } catch {
            // An older acpmux without the method, or no daemon: the composer says it could not resume.
            return .unavailable
        }
        switch resolved {
        case .success(let key):
            onOpenChat(key)
            return .opened
        case .failure(let status):
            return status
        }
    }
}
