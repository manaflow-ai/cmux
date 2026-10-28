import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextWakeups
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
    private struct Stage { var folder: URL; var file: URL; var name: String; var size: Int; var received: Int; var session: String; var expires: Date }
    private struct Batch { var session: String; var remaining: [AgentPaneUploadBatchEntry]; var expires: Date }
    private static var stages: [String: Stage] = [:]
    private static var batches: [String: Batch] = [:]
    /// How long a stage or a batch is kept after its last request.
    private static let stageLifetime: TimeInterval = 10 * 60
    /// How long an upload is kept: acpmux's `uploadsMaxAgeDays` default for its own (`config.rs`).
    nonisolated static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    /// The folder under ``root`` that holds a folder per chat (session ids are UUIDs, as upload
    /// folders' names are, so they never share one folder).
    nonisolated static let sessions = "sessions"

    /// The folder every local chat upload goes under.
    nonisolated static var root: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "cmux", directoryHint: .isDirectory)
            .appending(path: "Chat Uploads", directoryHint: .isDirectory)
    }

    /// The upload for chat tab `tab`, nil unless its folder is on this Mac (`isLocal`).
    static func uploader(tab: String, services: AppServices) -> AgentPaneUploader? {
        guard services.agentTabs.gitLink?(tab)?.isLocal == true, let root else { return nil }
        let session = services.agentTabs.session(of: tab).flatMap { isSessionName($0) ? $0 : nil }
        return { files in
            let chat = session.map { chatFolder($0, in: root) } ?? root
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
        let session = services.agentTabs.session(of: tab).flatMap { isSessionName($0) ? $0 : nil } ?? "new"
        let expiry = services.chatUploadExpiry, work = services.work
        return { request, sessionID in
            batches = batches.filter { $0.value.expires >= Date() }
            guard sessionID == nil || sessionID == session else { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
            switch request {
            case .begin(let name, let size, let batchToken, let manifest):
                if let batchToken {
                    guard let batch = batches[batchToken], batch.session == session, batch.remaining.first?.name == name, batch.remaining.first?.size == size else { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
                    let remaining = Array(batch.remaining.dropFirst())
                    if remaining.isEmpty { batches.removeValue(forKey: batchToken) }
                    else { batches[batchToken] = Batch(session: session, remaining: remaining, expires: Date().addingTimeInterval(stageLifetime)) }
                }
                guard size <= 1 * 1024 * 1024 * 1024 else { return AgentPaneReply.failure(code: "upload_refused", message: AgentChatUploadStrings.failed) }
                if let manifest {
                    guard manifest.first?.name == name, manifest.first?.size == size,
                          manifest.allSatisfy({ $0.size >= 0 && $0.size <= 1 * 1024 * 1024 * 1024 }),
                          manifest.reduce(0) { $0 + $1.size } <= 1 * 1024 * 1024 * 1024 else { return AgentPaneReply.failure(code: "upload_refused", message: AgentChatUploadStrings.failed) }
                }
                let token = UUID().uuidString.lowercased(), folder = root.appending(path: "staged-" + token, directoryHint: .isDirectory), file = folder.appending(path: name)
                do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) } } catch { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
                stages[token] = Stage(folder: folder, file: file, name: name, size: size, received: 0, session: session, expires: Date().addingTimeInterval(stageLifetime))
                var reply: [String: Any] = ["token": token, "size": size, "chunkSize": 512 * 1024]
                if let manifest, batchToken == nil, manifest.count > 1 {
                    let id = UUID().uuidString.lowercased()
                    batches[id] = Batch(session: session, remaining: Array(manifest.dropFirst()), expires: Date().addingTimeInterval(stageLifetime))
                    reply["batchToken"] = id
                }
                armExpiry(expiry, work: work)
                return AgentPaneReply.success(reply)
            case .chunk(let token, let offset, let data):
                guard var stage = stages[token], stage.session == session, stage.received == offset, offset + data.count <= stage.size, data.count <= 512 * 1024 else { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
                do { let handle = try FileHandle.blockingForWriting(to: stage.file); try handle.blockingSeekToEnd(); try handle.blockingWrite(contentsOf: data); try handle.close() } catch { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
                stage.received += data.count; stage.expires = Date().addingTimeInterval(stageLifetime); stages[token] = stage
                armExpiry(expiry, work: work)
                return AgentPaneReply.success(["offset": stage.received])
            case .finish(let token):
                guard let stage = stages[token], stage.session == session, stage.received == stage.size else { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
                let base = session == "new" ? root : chatFolder(session, in: root)
                let destination = base.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory).appending(path: "0", directoryHint: .isDirectory).appending(path: stage.name)
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.moveItem(at: stage.file, to: destination)
                    stages.removeValue(forKey: token)
                    try? FileManager.default.removeItem(at: stage.folder)
                } catch { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
                return AgentPaneReply.success(["path": destination.path])
            case .cancel(let token):
                if let stage = stages[token], stage.session == session {
                    stages.removeValue(forKey: token)
                    try? FileManager.default.removeItem(at: stage.folder)
                }
                return AgentPaneReply.success()
            }
        }
    }

    /// Takes out the stages and batches expired by `now`; answers the expired stages' folders and the next expiry.
    private static func purgeExpired(now: Date) -> (files: [URL], next: Date?) {
        let expired = stages.filter { $0.value.expires <= now }
        for token in expired.keys { stages.removeValue(forKey: token) }
        batches = batches.filter { $0.value.expires > now }
        return (expired.values.map(\.folder), nextExpiry)
    }

    /// The earliest expiry date of a stage or a batch, nil when none is left.
    private static var nextExpiry: Date? {
        (stages.values.map(\.expires) + batches.values.map(\.expires)).min()
    }

    /// Points `expiry` at the earliest stage or batch expiry, or drops it when none is left.
    private static func armExpiry(_ expiry: MainDeadline, work: BackgroundWork) {
        armStageExpiry(expiry, next: nextExpiry, work: work) { purgeExpired(now: $0) }
    }

    /// The expiry of a stager's stages and batches (this one's and ``AgentPeerUploads``'): one ``MainDeadline`` at
    /// the earliest date, moved after each purge, instead of a sleeping task per chunk. Points `deadline` at `next`
    /// (at least 1 s from `now`), or drops it when `next` is nil. At the deadline `purge` takes out what expired by
    /// the date it gets, its files are removed on the files lane (never on main), and the deadline moves to the next
    /// date. A chunk or a batch request that moves a date later re-arms, so it fires only for stages that expired.
    static func armStageExpiry(_ deadline: MainDeadline, next: Date?, work: BackgroundWork, now: @escaping @MainActor () -> Date = { Date() },
                               purge: @escaping @MainActor (_ now: Date) -> (files: [URL], next: Date?)) {
        guard let next else { deadline.cancel(); return }
        deadline.schedule(after: .seconds(max(1, next.timeIntervalSince(now())))) { [weak deadline] in
            let purged = purge(now())
            let files = purged.files
            if !files.isEmpty {
                work.post(.bestEffort, mayBlock: .files) { for file in files { try? FileManager.checked.removeItem(at: file) } }
            }
            if let deadline { armStageExpiry(deadline, next: purged.next, work: work, now: now, purge: purge) }
        }
    }

    /// Writes each file owner-only to `folder/<index>/<name>` (its own folder, so two files may share
    /// a name), with every folder owner-only too; the paths, in order.
    nonisolated static func write(_ files: [AgentPaneUpload], in folder: URL) throws -> [String] {
        let manager = FileManager.default, owner: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        // The root too, owner-only, when the chat's folder is the first under it.
        try FileManager.checked.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: owner)
        try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: false, attributes: owner)
        return try files.enumerated().map { index, file in
            let parent = folder.appending(path: String(index), directoryHint: .isDirectory)
            try FileManager.checked.createDirectory(at: parent, withIntermediateDirectories: false, attributes: owner)
            let url = parent.appending(path: file.name, directoryHint: .notDirectory)
            guard FileManager.checked.createFile(atPath: url.path, contents: file.data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return url.path
        }
    }
}

extension AgentChatUploads {
    /// Whether acpmux session id `id` names one folder: letters, digits, `-` and `_` only.
    nonisolated static func isSessionName(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Whether `name` is an upload folder's: a UUID, as ``uploader(tab:services:)`` names them.
    nonisolated static func isUploadName(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }

    /// The real folders in `folder` (not a symlink or a file), by name.
    nonisolated static func realFolders(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return entries.filter {
            let values = try? $0.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }

    /// Chat `session`'s folder under `root`.
    nonisolated static func chatFolder(_ session: String, in root: URL) -> URL {
        root.appending(path: sessions, directoryHint: .isDirectory).appending(path: session, directoryHint: .isDirectory)
    }

    /// Deletes chat `session`'s uploads under `root`: acpmux deleted the chat.
    nonisolated static func remove(session: String, in root: URL) {
        guard isSessionName(session) else { return }
        let chats = root.appending(path: sessions, directoryHint: .isDirectory)
        guard realFolders(in: root).contains(where: { $0.lastPathComponent == sessions }),
              realFolders(in: chats).contains(where: { $0.lastPathComponent == session }) else { return }
        try? FileManager.default.removeItem(at: chatFolder(session, in: root))
    }

    /// Deletes each upload under `root` made more than ``maximumAge`` before `now` (its folder's
    /// creation date), in a chat's folder or at the top (a chat that had no session yet, and every
    /// upload from before chats had folders), and a chat folder it leaves empty; answers how many uploads went. A folder not named as the app
    /// names it, a symlink or a file is kept.
    @discardableResult
    nonisolated static func sweep(_ root: URL, now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-maximumAge)
        var removed = 0
        func sweepUploads(in folder: URL) {
            for upload in realFolders(in: folder) where isUploadName(upload.lastPathComponent) {
                let made = (try? upload.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                if let made, made < cutoff, (try? FileManager.checked.removeItem(at: upload)) != nil { removed += 1 }
            }
        }
        sweepUploads(in: root)
        let chats = root.appending(path: sessions, directoryHint: .isDirectory)
        guard realFolders(in: root).contains(where: { $0.lastPathComponent == sessions }) else { return removed }
        for chat in realFolders(in: chats) where isSessionName(chat.lastPathComponent) {
            sweepUploads(in: chat)
            // rmdir(2) refuses a folder that is not empty: an upload written into it meanwhile stays.
            // SAFETY: rmdir reads the NUL-terminated copy of the path Swift makes for the call.
            _ = unsafe blockingRmdir(chat.path)
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
