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
        let generation = droppedPaths.generation
        guard let items = droppedPaths.takeItems(kind, names: names),
              let urls = await retainedDropURLs(items, generation: generation) else { return AgentPaneReply.success(["items": [Any]()]) }
        let links = await Self.attachItems(urls)
        guard generation == droppedPaths.generation else { return AgentPaneReply.success(["items": [Any]()]) }
        return AgentPaneReply.success(["items": links])
    }

    /// A macOS recording preview may disappear as soon as its drag ends. Its descriptor was
    /// pinned during the native drop; save those bytes through the same local upload owner that
    /// already owns permissions, session deletion and expiry. The one-shot native record is the
    /// authority here, so retaining it does not spend an unrelated composer gesture credit.
    private func retainedDropURLs(_ items: [AgentPaneDroppedPaths.Item], generation: UUID) async -> [URL]? {
        guard generation == droppedPaths.generation else { return nil }
        let recordings = items.enumerated().filter { $0.element.needsSnapshot }
        var urls = items.map(\.url)
        guard !recordings.isEmpty else { return urls }
        guard let uploader = onUpload?() else { return nil }
        var uploads: [AgentPaneUpload] = []
        for (_, item) in recordings {
            guard let snapshot = item.snapshot, let upload = await snapshot.upload(),
                  generation == droppedPaths.generation else { return nil }
            uploads.append(upload)
        }
        guard generation == droppedPaths.generation, onLocalPaths?() == true else { return nil }
        let reply = await uploader(uploads)
        guard generation == droppedPaths.generation, onLocalPaths?() == true, reply["ok"] as? Bool == true,
              let value = reply["value"] as? [String: Any], let saved = value["uploads"] as? [[String: Any]],
              saved.count == recordings.count else { return nil }
        for ((index, _), file) in zip(recordings, saved) {
            guard let path = file["path"] as? String, path.hasPrefix("/"),
                  (path as NSString).lastPathComponent == items[index].url.lastPathComponent else { return nil }
            urls[index] = URL(fileURLWithPath: path)
        }
        droppedPaths.retain(recordings.map { urls[$0.offset].path })
        return urls
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
