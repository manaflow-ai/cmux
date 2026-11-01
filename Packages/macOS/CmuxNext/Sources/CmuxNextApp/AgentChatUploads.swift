import CmuxNextAgentPane
import Foundation

/// Files the person drops or pastes into a chat on this Mac that the composer can't attach as a
/// prompt block (a binary, a text file over the inline limit): any file attaches (Lawrence
/// 2026-10-20). The page sends their bytes (``AgentPaneUpload``, the same `chat.upload` call a
/// Cloud chat's upload uses), and only for a chat whose folder is on this Mac, with a real gesture
/// in its pane, the app writes them owner-only under `~/Library/Application Support/cmux/Chat
/// Uploads/sessions/<session>/<random>/<index>/<name>` (`<random>/...` for a new chat with no session yet)
/// and answers where each is, so the composer puts the paths in the prompt and the agent opens them
/// with its own tools. A chat's files go when this Mac's acpmux deletes the chat
/// (``remove(session:in:)``, ``AgentTurnStateFeed/deletesSession(_:)``: not a peer's purge, nor the
/// copy Bring Back replaces), and any upload goes once it is older than ``maximumAge``
/// (``sweep(_:now:)``, at launch), as acpmux does its own uploads (`file_uploads.rs`). A chat
/// deleted while the app was not watching keeps its folder until the sweep. Only folders named as
/// the app names them are deleted.
@MainActor
struct AgentChatUploads {
    private struct Stage { var folder: URL; var file: URL; var name: String; var size: Int; var received: Int; var session: String; var tab: String; var expires: Date }
    private struct Batch { var session: String; var tab: String; var remaining: [AgentPaneUploadBatchEntry]; var expires: Date }
    private static var stages: [String: Stage] = [:]
    private static var batches: [String: Batch] = [:]
    /// How long an upload is kept: acpmux's `uploadsMaxAgeDays` default for its own (`config.rs`).
    nonisolated static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    /// The folder under ``root`` that holds a folder per chat (``ChatUploadFolders``).
    nonisolated static let sessions = ChatUploadFolders.sessions
    /// The folder every local chat upload goes under.
    nonisolated static var root: URL? { ChatUploadFolders.standard?.root }

    /// The upload for chat tab `tab`, nil unless its folder is on this Mac (`isLocal`).
    static func uploader(tab: String, services: AppServices) -> AgentPaneUploader? {
        guard services.agentTabs.gitLink?(tab)?.isLocal == true, let root else { return nil }
        let session = services.agentTabs.session(of: tab).flatMap { ChatUploadFolders.isSessionName($0) ? $0 : nil }
        return { files in
            let chat = session.map { ChatUploadFolders(root: root).chat($0) } ?? root
            let folder = chat.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
            do {
                let paths = try await Task.detached { try write(files, in: folder) }.value
                let uploads = zip(files, paths).map { file, path -> [String: Any] in ["name": file.name, "path": path] }
                return AgentPaneReply.success(["uploads": uploads])
            } catch {
                return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed)
            }
        }
    }

    static func stager(tab: String, services: AppServices) -> AgentPaneUploadStager? {
        guard services.agentTabs.gitLink?(tab)?.isLocal == true, let root else { return nil }
        let session = services.agentTabs.session(of: tab).flatMap { ChatUploadFolders.isSessionName($0) ? $0 : nil } ?? "new"
        // An upload stays in its own tab, by its store id (a new tab's provisional id is rekeyed). One begun with no session ("new")
        // goes on once the chat starts (the prompt was sent while it streamed, #28647); another new chat's page never feeds it.
        let mine = { (made: String, by: String) in services.agentTabs.resolve(by) == tab && (made == session || made == "new") }
        return stager(root: root, session: session, tab: tab, mine: mine)
    }

    /// Test and native callers that already have a local upload root use the
    /// same staging state machine without an AppServices tab resolver.
    static func stager(root: URL, session: String) -> AgentPaneUploadStager {
        stager(root: root, session: session, tab: "", mine: { made, _ in made == session || made == "new" })
    }

    private static func stager(root: URL, session: String, tab: String,
                               mine: @escaping (String, String) -> Bool) -> AgentPaneUploadStager {
        return { request, sessionID in
            batches = batches.filter { $0.value.expires >= Date() }
            guard sessionID == nil || sessionID == session else { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
            switch request {
            case .begin(let name, let size, let batchToken, let manifest):
                if let batchToken {
                    guard let batch = batches[batchToken], mine(batch.session, batch.tab), batch.remaining.first?.name == name, batch.remaining.first?.size == size else { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
                    let remaining = Array(batch.remaining.dropFirst())
                    if remaining.isEmpty { batches.removeValue(forKey: batchToken) }
                    else { batches[batchToken] = Batch(session: batch.session, tab: batch.tab, remaining: remaining, expires: Date().addingTimeInterval(10 * 60)) }
                }
                guard size >= 0 else { return AgentPaneReply.failure(code: "upload_refused", message: AgentChatUploadStrings.failed) }
                if let manifest {
                    guard manifest.first?.name == name, manifest.first?.size == size,
                          manifest.allSatisfy({ $0.size >= 0 }) else { return AgentPaneReply.failure(code: "upload_refused", message: AgentChatUploadStrings.failed) }
                }
                let token = UUID().uuidString.lowercased(), folder = root.appending(path: "staged-" + token, directoryHint: .isDirectory), file = folder.appending(path: name)
                do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) } } catch { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
                stages[token] = Stage(folder: folder, file: file, name: name, size: size, received: 0, session: session, tab: tab, expires: Date().addingTimeInterval(10 * 60))
                expire(token)
                var reply: [String: Any] = ["token": token, "size": size, "chunkSize": 512 * 1024]
                if let manifest, batchToken == nil, manifest.count > 1 {
                    let id = UUID().uuidString.lowercased()
                    batches[id] = Batch(session: session, tab: tab, remaining: Array(manifest.dropFirst()), expires: Date().addingTimeInterval(10 * 60))
                    reply["batchToken"] = id
                }
                return AgentPaneReply.success(reply)
            case .chunk(let token, let offset, let data):
                guard var stage = stages[token], mine(stage.session, stage.tab), stage.received == offset, data.count <= stage.size - offset, data.count <= 512 * 1024 else { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
                do { let handle = try FileHandle(forWritingTo: stage.file); try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close() } catch { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
                stage.received += data.count; stage.expires = Date().addingTimeInterval(10 * 60); stages[token] = stage
                expire(token)
                return AgentPaneReply.success(["offset": stage.received])
            case .finish(let token):
                guard let stage = stages[token], mine(stage.session, stage.tab), stage.received == stage.size else { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
                let base = session == "new" ? root : ChatUploadFolders(root: root).chat(session)
                let destination = base.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory).appending(path: "0", directoryHint: .isDirectory).appending(path: stage.name)
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.moveItem(at: stage.file, to: destination)
                    stages.removeValue(forKey: token)
                    try? FileManager.default.removeItem(at: stage.folder)
                } catch { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
                return AgentPaneReply.success(["path": destination.path])
            case .cancel(let token):
                if let stage = stages[token], mine(stage.session, stage.tab) {
                    stages.removeValue(forKey: token)
                    try? FileManager.default.removeItem(at: stage.folder)
                }
                return AgentPaneReply.success()
            }
        }
    }

    /// Drops stage `token` and its file once it has had no chunk for ten minutes.
    private static func expire(_ token: String) {
        Task { @MainActor in
            // wakeup-allow: one-shot stage expiry; a later chunk refreshes the expiry date.
            try? await Task.sleep(for: .seconds(10 * 60))
            guard let expired = stages[token], expired.expires <= Date() else { return }
            stages.removeValue(forKey: token)
            await Task.detached(priority: .utility) { [folder = expired.folder] in try? FileManager.default.removeItem(at: folder) }.value
        }
    }

    /// Writes each file owner-only to `folder/<index>/<name>` (its own folder, so two files may share
    /// a name), with every folder owner-only too; the paths, in order.
    nonisolated static func write(_ files: [AgentPaneUpload], in folder: URL) throws -> [String] {
        let manager = FileManager.default, owner: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        // The root too, owner-only, when the chat's folder is the first under it.
        try manager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: owner)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: owner)
        return try files.enumerated().map { index, file in
            let parent = folder.appending(path: String(index), directoryHint: .isDirectory)
            try manager.createDirectory(at: parent, withIntermediateDirectories: false, attributes: owner)
            let url = parent.appending(path: file.name, directoryHint: .notDirectory)
            guard manager.createFile(atPath: url.path, contents: file.data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return url.path
        }
    }
}

extension AgentChatUploads {
    /// The real folders in `folder` (not a symlink or a file), by name.
    nonisolated static func realFolders(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return entries.filter {
            let values = try? $0.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }

    /// Deletes chat `session`'s uploads under `root`: acpmux deleted the chat.
    nonisolated static func remove(session: String, in root: URL) {
        guard ChatUploadFolders.isSessionName(session) else { return }
        let chats = root.appending(path: sessions, directoryHint: .isDirectory)
        guard realFolders(in: root).contains(where: { $0.lastPathComponent == sessions }),
              realFolders(in: chats).contains(where: { $0.lastPathComponent == session }) else { return }
        try? FileManager.default.removeItem(at: ChatUploadFolders(root: root).chat(session))
    }

    /// Deletes each upload under `root` made more than ``maximumAge`` before `now` (its folder's
    /// creation date), in a chat's folder or at the top (a chat that had no session yet, and every
    /// upload from before chats had folders), and a chat folder it leaves empty; answers how many uploads went. A folder not named as the app
    /// names it, a symlink or a file is kept.
    @discardableResult
    nonisolated static func sweep(_ root: URL, now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-maximumAge)
        let manager = FileManager.default
        var removed = 0
        func sweepUploads(in folder: URL) {
            for upload in realFolders(in: folder) where ChatUploadFolders.isUploadName(upload.lastPathComponent) {
                let made = (try? upload.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                if let made, made < cutoff, (try? manager.removeItem(at: upload)) != nil { removed += 1 }
            }
        }
        sweepUploads(in: root)
        let chats = root.appending(path: sessions, directoryHint: .isDirectory)
        guard realFolders(in: root).contains(where: { $0.lastPathComponent == sessions }) else { return removed }
        for chat in realFolders(in: chats) where ChatUploadFolders.isSessionName(chat.lastPathComponent) {
            sweepUploads(in: chat)
            // rmdir(2) refuses a folder that is not empty: an upload written into it meanwhile stays.
            _ = rmdir(chat.path)
        }
        return removed
    }

    /// ``sweep(_:now:)`` of ``root`` off the main thread (at launch).
    static func sweepInBackground() {
        guard let root else { return }
        // task-owner: one sweep of the Chat Uploads folder; nothing waits for it
        Task.detached(priority: .utility) { sweep(root, now: Date()) }
    }

    /// ``remove(session:in:)`` under ``root`` off the main thread (acpmux deleted the chat).
    static func removeInBackground(session: String) {
        guard let root else { return }
        // task-owner: one delete of a deleted chat's uploads; nothing waits for it
        Task.detached(priority: .utility) { remove(session: session, in: root) }
    }
}

/// A local chat upload's failure text, shown in the composer. Keys live in Resources/Cloud.xcstrings
/// beside the Cloud chat upload's.
enum AgentChatUploadStrings {
    static var failed: String {
        String(localized: "chat.upload.localFailed", defaultValue: "Couldn't save the file on this Mac.", table: "Cloud", bundle: .module)
    }
}
