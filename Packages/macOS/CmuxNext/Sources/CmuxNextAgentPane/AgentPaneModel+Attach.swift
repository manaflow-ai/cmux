import Foundation

extension AgentPaneModel {
    /// The summary panel's Attach files or folders (`chat.attach.choose`): the open panel only
    /// after a real gesture (it spends the gesture's grant credit). It answers
    /// `{items: [{path, folder}]}`; a cancelled pick answers no value. The caller refuses a chat
    /// on another machine first.
    func chooseAttachments() async -> [String: Any] {
        guard let onChooseAttachments else { return Self.unsupported("chat.attach.choose") }
        guard transport.gestures.consume() else { return Self.transportFailure(.gestureRequired) }
        let picks = await onChooseAttachments()
        guard !picks.isEmpty else { return AgentPaneReply.success() }
        // Whether each pick is a folder reads the file system: off the main actor. The panel's URLs
        // are not relied on for a trailing slash.
        let kinds = await Task.detached(priority: .userInitiated) {
            picks.map { url in
                let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
                return (path: url.path, folder: folder)
            }
        }.value
        let items: [[String: Any]] = kinds.map { ["path": $0.path, "folder": $0.folder] }
        return AgentPaneReply.success(["items": items])
    }
}
