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

    /// A macOS screenshot or recording preview may disappear as soon as its drag ends. Its
    /// descriptor was pinned during the native drop; its bytes are kept in this chat's Chat Uploads
    /// folder (``ChatUploadFolders``, the layout the App's local upload owner writes, so its session
    /// deletion and expiry cover it) as an APFS clone, or a chunked copy, of any size. The one-shot
    /// native record is the authority here, so keeping it does not spend a composer gesture credit.
    private func retainedDropURLs(_ items: [AgentPaneDroppedPaths.Item], generation: UUID) async -> [URL]? {
        guard generation == droppedPaths.generation else { return nil }
        let recordings = items.enumerated().filter { $0.element.needsSnapshot }
        var urls = items.map(\.url)
        guard !recordings.isEmpty else { return urls }
        guard let folders = chatUploadFolders else { return nil }
        let upload = folders.freshUpload(session: sessionId)
        for (at, (index, item)) in recordings.enumerated() {
            guard let snapshot = item.snapshot,
                  let saved = await snapshot.save(into: upload.appending(path: String(at), directoryHint: .isDirectory)),
                  generation == droppedPaths.generation, onLocalPaths?() == true else {
                await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: upload) }.value
                return nil
            }
            urls[index] = saved
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
