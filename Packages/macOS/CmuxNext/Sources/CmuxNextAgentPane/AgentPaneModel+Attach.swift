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
        return AgentPaneReply.success(["items": await Self.attachItems(picks)])
    }

    /// Where the files of the person's last native drop or paste are (`chat.attach.dropped`), for a
    /// chat the App calls local (``onLocalPaths``): `{items: [{path, folder}]}` in the order of
    /// `names`, or no items when the page's files are not that drop's or paste's
    /// (``AgentPaneDroppedPaths``). It uses no gesture: only the person's own drop or paste fills
    /// the record. The caller refuses a chat on another machine first.
    func attachDropped(_ kind: AgentPaneDroppedPaths.Kind, names: [String]) async -> [String: Any] {
        guard onLocalPaths?() == true else { return Self.unsupported("chat.attach.dropped") }
        guard let urls = droppedPaths.take(kind, names: names) else { return AgentPaneReply.success(["items": [Any]()]) }
        return AgentPaneReply.success(["items": await Self.attachItems(urls)])
    }

    /// Each file or folder of `urls` as the page's link item `{path, folder}`. Whether each is a
    /// folder reads the file system: off the main actor. A URL's trailing slash is not relied on.
    static func attachItems(_ urls: [URL]) async -> [[String: Any]] {
        let kinds = await Task.detached(priority: .userInitiated) {
            urls.map { url in
                let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
                return (path: url.path, folder: folder)
            }
        }.value
        return kinds.map { ["path": $0.path, "folder": $0.folder] }
    }
}
