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
    /// The book of files streaming into chats on this Mac, staged under ``root``
    /// (`staged-<random>/<name>`): one for the app, ``AppServices/chatUploads``.
    static func stages() -> AgentPaneUploadStages<AgentPaneUploadFile> {
        AgentPaneUploadStages(owner: "AgentChatUploads.stageExpiry") { file in
            // task-owner: one delete of an expired upload's partial file; nothing waits for it
            Task { await file.discard() }
        }
    }
    /// How long an upload is kept: acpmux's `uploadsMaxAgeDays` default for its own (`config.rs`).
    nonisolated static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    /// The folder under ``root`` that holds a folder per chat (session ids are UUIDs, as upload
    /// folders' names are, so they never share one folder).
    nonisolated static let sessions = "sessions"
    /// The session name of a new chat's uploads (no session yet): they go at the top of ``root``.
    nonisolated static let newChat = "new"

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

    /// The streamed upload for chat tab `tab` (``stage(_:session:root:stages:freeBytes:)``), nil
    /// unless its folder is on this Mac.
    static func stager(tab: String, services: AppServices) -> AgentPaneUploadStager? {
        guard services.agentTabs.gitLink?(tab)?.isLocal == true, let root else { return nil }
        let session = services.agentTabs.session(of: tab).flatMap { isSessionName($0) ? $0 : nil } ?? newChat
        let stages = services.chatUploads
        return { request, sessionID in
            guard sessionID == nil || sessionID == session else { return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed) }
            return await stage(request, session: session, root: root, stages: stages)
        }
    }

    /// One step of a file streamed into chat `session` under `root`. A file of any size goes while
    /// this Mac's disk has room for it; each chunk is decoded and written off the main thread
    /// (``AgentPaneUploadFile``), and a cancel deletes what was written. The finished file moves to the
    /// chat's folder, `<random>/0/<name>`, and the reply names its path.
    static func stage(_ request: AgentPaneUploadStageRequest, session: String, root: URL, stages: AgentPaneUploadStages<AgentPaneUploadFile>,
                      freeBytes: @escaping @Sendable (URL) -> Int64? = AgentPaneUploadFile.freeBytes) async -> [String: Any] {
        let failed = AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed)
        switch request {
        case .begin(let name, let size, let batchToken, let manifest):
            guard case .admitted(let batch) = stages.admit(name: name, size: size, batchToken: batchToken, manifest: manifest, session: session) else { return failed }
            let folder = root.appending(path: "staged-" + UUID().uuidString.lowercased(), directoryHint: .isDirectory)
            let file: AgentPaneUploadFile
            do throws(AgentPaneUploadFile.Failure) {
                file = try await AgentPaneUploadFile.make(folder: folder, name: name, size: size, freeBytes: freeBytes)
            } catch {
                return reply(error, name: name) ?? failed
            }
            var reply: [String: Any] = ["token": stages.add(file, name: name, size: size, session: session), "size": size,
                                        "chunkSize": AgentPaneUploadStageRequest.maximumChunkBytes]
            if let batch { reply["batchToken"] = batch }
            return AgentPaneReply.success(reply)
        case .chunk(let token, let offset, let base64):
            guard let stage = stages.stage(token, session: session) else { return failed }
            do throws(AgentPaneUploadFile.Failure) {
                return AgentPaneReply.success(["offset": try await stage.upload.append(offset: offset, base64: base64)])
            } catch {
                // A full disk ends the upload at once, so its space comes back.
                guard let full = reply(error, name: stage.name) else { return failed }
                stages.remove(token, session: session)
                await stage.upload.discard()
                return full
            }
        case .finish(let token):
            guard let stage = stages.remove(token, session: session) else { return failed }
            let base = session == newChat ? root : chatFolder(session, in: root)
            let destination = base.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
                .appending(path: "0", directoryHint: .isDirectory).appending(path: stage.name)
            do {
                return AgentPaneReply.success(["path": try await stage.upload.finish(movingTo: destination).path])
            } catch {
                return failed
            }
        case .cancel(let token):
            if let stage = stages.remove(token, session: session) { await stage.upload.discard() }
            return AgentPaneReply.success()
        }
    }

    /// The reply for a disk that lacks room for file `name`; nil for any other failure.
    private static func reply(_ failure: AgentPaneUploadFile.Failure, name: String) -> [String: Any]? {
        guard case .noSpace(let free) = failure else { return nil }
        return AgentPaneReply.failure(code: "no_space", message: AgentChatUploadStrings.noSpace(name, freeBytes: free))
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
    /// Whether acpmux session id `id` names one folder: letters, digits, `-` and `_` only.
    nonisolated static func isSessionName(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Whether `name` is an upload folder's: a UUID, as ``uploader(tab:services:)`` names them.
    nonisolated static func isUploadName(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }

    /// Whether `name` is a streamed upload's staging folder: `staged-<UUID>`, as
    /// ``stage(_:session:root:stages:freeBytes:)`` names them.
    nonisolated static func isStageName(_ name: String) -> Bool {
        name.hasPrefix("staged-") && isUploadName(String(name.dropFirst("staged-".count)))
    }

    /// How old a staging folder gets before the sweep deletes it: its upload was never finished or
    /// cancelled (the app quit part way).
    nonisolated static let maximumStageAge: TimeInterval = 24 * 60 * 60

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
    /// upload from before chats had folders), each staging folder older than ``maximumStageAge``,
    /// and a chat folder it leaves empty; answers how many uploads went. A folder not named as the app
    /// names it, a symlink or a file is kept.
    @discardableResult
    nonisolated static func sweep(_ root: URL, now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-maximumAge)
        let manager = FileManager.default
        var removed = 0
        func sweepUploads(in folder: URL, named isNamed: (String) -> Bool, before cutoff: Date) {
            for upload in realFolders(in: folder) where isNamed(upload.lastPathComponent) {
                let made = (try? upload.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                if let made, made < cutoff, (try? manager.removeItem(at: upload)) != nil { removed += 1 }
            }
        }
        sweepUploads(in: root, named: isUploadName, before: cutoff)
        sweepUploads(in: root, named: isStageName, before: now.addingTimeInterval(-maximumStageAge))
        let chats = root.appending(path: sessions, directoryHint: .isDirectory)
        guard realFolders(in: root).contains(where: { $0.lastPathComponent == sessions }) else { return removed }
        for chat in realFolders(in: chats) where isSessionName(chat.lastPathComponent) {
            sweepUploads(in: chat, named: isUploadName, before: cutoff)
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
    static func noSpace(_ name: String, freeBytes: Int64) -> String {
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return String(localized: "chat.upload.localNoSpace", defaultValue: "Not enough space on this Mac for \(name) (\(free) free).", table: "Cloud", bundle: .module)
    }
}
