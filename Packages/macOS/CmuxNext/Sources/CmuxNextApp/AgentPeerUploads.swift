import CmuxNextAgentActivity
import CmuxNextAgentPane
import Foundation

/// Files the person drops or pastes into a chat whose agent runs on an ssh peer (acpmux peering:
/// this Mac's acpmux mirrors the chat, named `huge-blue/<name>`) that the composer can't attach as
/// a prompt block. The page streams each one in chunks (``AgentPaneUploadStageRequest``), and only
/// for such a chat, with a real gesture in its pane, the app sends each chunk on as it comes,
/// through this Mac's acpmux to the daemon that owns the chat (`_acpmux/file_put_begin`, `_chunk`,
/// `_finish`), which writes it owner-only on that machine and answers where. Nothing of the file is
/// kept on this Mac, a file has any size that machine's disk has room for, and a cancel deletes
/// what was written there. The composer puts those paths in the prompt and the agent opens them
/// there. An acpmux from before those methods, here or on the peer, answers `unsupported`, so the
/// composer keeps its own note.
@MainActor
struct AgentPeerUploads {
    /// The peer chat tab `tab` shows: its session, the peer's name and the pane's acpmux.
    struct Target: Sendable {
        var session: String
        var machine: String
        var host: any AgentPaneHostProviding
    }

    /// A file streaming to a peer: the chat it is for and the upload the peer named.
    struct Upload: Sendable {
        var target: Target
        var id: String
    }

    /// The files streaming to peers.
    private static let stages = AgentUploadStages<Upload>(owner: "AgentPeerUploads.stageExpiry") { upload in
        // task-owner: one cancel of an expired upload on its peer, which deletes its partial file there; nothing waits for it
        Task { await cancel(upload) }
    }

    /// The upload for chat tab `tab`, nil unless it is a peer's chat (``target(tab:services:)``).
    static func uploader(tab: String, services: AppServices) -> AgentPaneUploader? {
        guard let target = target(tab: tab, services: services) else { return nil }
        return { files in
            await upload(files, machine: target.machine) { name, data in
                try await target.host.putFile(sessionId: target.session, name: name, data: data)
            }
        }
    }

    /// The streamed upload for chat tab `tab` (``stage(_:target:stages:)``), nil unless it is a
    /// peer's chat.
    static func stager(tab: String, services: AppServices) -> AgentPaneUploadStager? {
        guard let target = target(tab: tab, services: services) else { return nil }
        return { request, session in
            // A page with no session yet answers as before streams were taken: the page's own note.
            guard let session else { return AgentPaneReply.failure(code: "unsupported", message: AgentPeerUploadStrings.failed(target.machine)) }
            guard session == target.session else { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
            return await stage(request, target: target, stages: stages)
        }
    }

    /// One step of a file streamed to `target`'s machine, sent on as it comes (the chunk's base64
    /// text as the page sent it). A step that fails part way cancels the upload there.
    static func stage(_ request: AgentPaneUploadStageRequest, target: Target, stages: AgentUploadStages<Upload>) async -> [String: Any] {
        let session = target.session, failed = AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine))
        switch request {
        case .begin(let name, let size, let batchToken, let manifest):
            guard case .admitted(let batch) = stages.admit(name: name, size: size, batchToken: batchToken, manifest: manifest, session: session) else { return failed }
            let progress: AgentPaneFilePutProgress
            do {
                progress = try await target.host.putFile(sessionId: session, step: .begin(name: name, size: size))
            } catch {
                return reply(AgentPaneFilePutFailure(error), name: name, machine: target.machine)
            }
            guard case .begun(let id) = progress else { return failed }
            var reply: [String: Any] = ["token": stages.add(Upload(target: target, id: id), name: name, size: size, session: session), "size": size,
                                        "chunkSize": AgentPaneUploadStageRequest.maximumChunkBytes]
            if let batch { reply["batchToken"] = batch }
            return AgentPaneReply.success(reply)
        case .chunk(let token, let offset, let base64):
            guard let stage = stages.stage(token, session: session) else { return failed }
            do {
                let progress = try await target.host.putFile(sessionId: session, step: .chunk(upload: stage.upload.id, offset: offset, base64: base64))
                guard case .wrote(let next) = progress else { return failed }
                return AgentPaneReply.success(["offset": next])
            } catch {
                let failure = AgentPaneFilePutFailure(error)
                // A full disk ends the upload at once (the peer already deleted its partial file).
                if case .noSpace = failure { stages.remove(token, session: session) }
                return reply(failure, name: stage.name, machine: target.machine)
            }
        case .finish(let token):
            guard let stage = stages.remove(token, session: session) else { return failed }
            do {
                let progress = try await target.host.putFile(sessionId: session, step: .finish(upload: stage.upload.id, name: stage.name, size: stage.size))
                guard case .saved(let path) = progress else { await cancel(stage.upload); return failed }
                return AgentPaneReply.success(["path": path])
            } catch {
                await cancel(stage.upload)
                return reply(AgentPaneFilePutFailure(error), name: stage.name, machine: target.machine)
            }
        case .cancel(let token):
            if let stage = stages.remove(token, session: session) { await cancel(stage.upload) }
            return AgentPaneReply.success()
        }
    }

    /// Deletes `upload`'s partial file on its peer (`_acpmux/file_put_cancel`, which the peer takes
    /// again and again); a peer that does not answer deletes it with its own sweep.
    private static func cancel(_ upload: Upload) async {
        _ = try? await upload.target.host.putFile(sessionId: upload.target.session, step: .cancel(upload: upload.id))
    }

    /// Tab `tab`'s chat when its pane attaches to this Mac's acpmux and that acpmux lists its
    /// session as a peer's (``AgentActivityLane/peer``, from the same `_acpmux/watch` the page
    /// reads its chat's `peer` from).
    static func target(tab: String, services: AppServices) -> Target? {
        let tabs = services.agentTabs
        guard tabs.gitLink?(tab)?.isLocal == true, let session = tabs.session(of: tab),
              let machine = peer(of: session, lanes: AgentLaneStore.shared) else { return nil }
        // The pane's own acpmux (`AgentTabStore.view(for:)`).
        return Target(session: session, machine: machine, host: tabs.localSessionHost ?? tabs.host)
    }

    /// The acpmux peer that runs `session`, nil for a chat of this Mac's acpmux (or one it does
    /// not list).
    static func peer(of session: String, lanes: AgentLaneStore) -> String? {
        lanes.links(session)?.peer.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The reply to the page's whole-file upload (an older page): each file put in turn with `put`,
    /// which answers its path on `machine`.
    static func upload(_ files: [AgentPaneUpload], machine: String,
                       put: (_ name: String, _ data: Data) async throws -> String) async -> [String: Any] {
        var uploads: [[String: Any]] = []
        for file in files {
            do {
                let path = try await put(file.name, file.data)
                uploads.append(["name": file.name, "path": path])
            } catch {
                return reply(AgentPaneFilePutFailure(error), name: file.name, machine: machine)
            }
        }
        return AgentPaneReply.success(["uploads": uploads])
    }

    static func reply(_ failure: AgentPaneFilePutFailure, name: String = "", machine: String) -> [String: Any] {
        switch failure {
        // The page's own note: this chat takes no uploads (cloudUploads.ts `NOT_TAKEN`).
        case .unsupported: AgentPaneReply.failure(code: "unsupported", message: AgentPeerUploadStrings.failed(machine))
        case .tooLarge: AgentPaneReply.failure(code: "too_large", message: AgentPeerUploadStrings.tooLarge(machine))
        case .noSpace(let free):
            AgentPaneReply.failure(code: "no_space", message: AgentPeerUploadStrings.noSpace(name, machine: machine, freeBytes: free))
        case .failed: AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(machine))
        }
    }
}

/// A peer chat upload's failure text, shown in the composer. Keys live in Resources/Cloud.xcstrings
/// beside the Cloud and local chat uploads'.
enum AgentPeerUploadStrings {
    static func failed(_ machine: String) -> String {
        String(localized: "chat.upload.peerFailed", defaultValue: "Couldn't send the file to \(machine).", table: "Cloud", bundle: .module)
    }
    static func tooLarge(_ machine: String) -> String {
        String(localized: "chat.upload.peerTooLarge", defaultValue: "This file is too large to send to \(machine).", table: "Cloud", bundle: .module)
    }
    static func noSpace(_ name: String, machine: String, freeBytes: Int64) -> String {
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return String(localized: "chat.upload.peerNoSpace", defaultValue: "Not enough space on \(machine) for \(name) (\(free) free).", table: "Cloud", bundle: .module)
    }
}
