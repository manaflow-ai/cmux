import CmuxNextSettings
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
        let items = await Self.attachItems(picks)
        droppedPaths.linked(Self.paths(of: items))
        return AgentPaneReply.success(["items": items])
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
        droppedPaths.linked(Self.paths(of: links))
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

    /// The paths, files and folders, of link items made by ``attachItems(_:)``.
    nonisolated static func paths(of items: [[String: Any]]) -> [String] {
        items.compactMap { $0["path"] as? String }
    }

    /// The Mac files and folders of a new chat's first-send chips that may go to Cloud (``AgentPaneCloudStart/carriedFiles``):
    /// a `link` chip's path when it is a file or folder this pane handed the page from the person's own drop,
    /// paste or pick (``AgentPaneDroppedPaths/linkedFiles``), or a `saved` chip's file this app wrote
    /// under Chat Uploads (``ChatUploadFolders``), which are also answered as `saved`. A path page
    /// script made up is never one, and a folder is never `saved`.
    func cloudCarriedFiles(_ attachments: [JSONValue]) async -> (files: Set<String>, saved: Set<String>) {
        let linked = Set(droppedPaths.linkedFiles), root = chatUploadFolders?.root
        let asked = attachments.compactMap { chip -> (path: String, saved: Bool)? in
            guard chip["kind"]?.stringValue == "link", let path = chip["path"]?.stringValue,
                  path.hasPrefix("/"), !path.contains("\0") else { return nil }
            if linked.contains(path) { return (path, false) }
            return chip["saved"]?.boolValue == true ? (path, true) : nil
        }
        guard !asked.isEmpty else { return ([], []) }
        return await Task.detached(priority: .userInitiated) {
            var files: Set<String> = [], saved: Set<String> = []
            for (path, _) in asked {
                var folder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &folder) else { continue }
                // A folder goes only as the person's own drop or pick named it.
                if folder.boolValue {
                    if linked.contains(path) { files.insert(path) }
                    continue
                }
                // A drop's own recording snapshot lives under Chat Uploads too: staged like a saved chip.
                let under = root.map { Self.isSavedUpload(path, root: $0) } ?? false
                guard linked.contains(path) || under else { continue }
                files.insert(path)
                if under { saved.insert(path) }
            }
            return (files, saved)
        }.value
    }

    /// Whether `path`, its links resolved, is a file under the Chat Uploads folder `root`.
    nonisolated static func isSavedUpload(_ path: String, root: URL) -> Bool {
        let top = root.resolvingSymlinksInPath().standardizedFileURL.path
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return file.hasPrefix(top.hasSuffix("/") ? top : top + "/")
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
