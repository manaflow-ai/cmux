import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation
import CmuxNextCompat

/// Files the person drops or pastes into a chat whose agent runs on an ssh peer (acpmux peering:
/// this Mac's acpmux mirrors the chat, named `huge-blue/<name>`) that the composer can't attach as
/// a prompt block. The page sends their bytes (``AgentPaneUpload``, the same `chat.upload` a local
/// or Cloud chat's upload uses), and only for such a chat, with a real gesture in its pane, the
/// app sends each one through this Mac's acpmux to the daemon that owns the chat
/// (`_acpmux/file_put`), which saves it owner-only on that machine and answers where. The composer
/// puts those paths in the prompt and the agent opens them there. An acpmux from before that
/// method, here or on the peer, answers `unsupported`, so the composer keeps its own note.
@MainActor
struct AgentPeerUploads {
    private struct Stage { var target: Target; var file: URL; var name: String; var size: Int; var received: Int; var expires: Date }
    private struct Batch { var session: String; var remaining: [AgentPaneUploadBatchEntry]; var expires: Date }
    private static var stages: [String: Stage] = [:]
    private static var batches: [String: Batch] = [:]
    /// How long a stage or a batch is kept after its last request.
    private static let stageLifetime: TimeInterval = 10 * 60
    /// The peer chat tab `tab` shows: its session, the peer's name and the pane's acpmux.
    struct Target {
        var session: String
        var machine: String
        var host: any AgentPaneHostProviding
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

    static func stager(tab: String, services: AppServices) -> AgentPaneUploadStager? {
        guard let target = target(tab: tab, services: services) else { return nil }
        let expiry = services.peerUploadExpiry, work = services.work
        return { request, session in
            batches = batches.filter { $0.value.expires >= Date() }
            guard session == target.session else { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
            switch request {
            case .begin(let name, let size, let batchToken, let manifest):
                if let batchToken {
                    guard let batch = batches[batchToken], batch.session == target.session, batch.remaining.first?.name == name, batch.remaining.first?.size == size else { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
                    let remaining = Array(batch.remaining.dropFirst())
                    if remaining.isEmpty { batches.removeValue(forKey: batchToken) }
                    else { batches[batchToken] = Batch(session: target.session, remaining: remaining, expires: Date().addingTimeInterval(stageLifetime)) }
                }
                guard size <= AgentPaneUpload.maximumPeerFileBytes else { return AgentPaneReply.failure(code: "too_large", message: AgentPeerUploadStrings.tooLarge(target.machine)) }
                if let manifest {
                    guard manifest.first?.name == name, manifest.first?.size == size,
                          manifest.allSatisfy({ $0.size >= 0 && $0.size <= AgentPaneUpload.maximumPeerFileBytes }),
                          manifest.reduce(0) { $0 + $1.size } <= AgentPaneUpload.maximumTotalBytes else { return AgentPaneReply.failure(code: "too_large", message: AgentPeerUploadStrings.tooLarge(target.machine)) }
                }
                let token = UUID().uuidString.lowercased(), file = FileManager.default.temporaryDirectory.appending(path: "cmux-peer-staged-" + token + "-" + name)
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
                stages[token] = Stage(target: target, file: file, name: name, size: size, received: 0, expires: Date().addingTimeInterval(stageLifetime))
                var reply: [String: Any] = ["token": token, "size": size, "chunkSize": 512 * 1024]
                if let manifest, batchToken == nil, manifest.count > 1 {
                    let id = UUID().uuidString.lowercased()
                    batches[id] = Batch(session: target.session, remaining: Array(manifest.dropFirst()), expires: Date().addingTimeInterval(stageLifetime))
                    reply["batchToken"] = id
                }
                armExpiry(expiry, work: work)
                return AgentPaneReply.success(reply)
            case .chunk(let token, let offset, let data):
                guard var stage = stages[token], stage.target.session == target.session, stage.received == offset, offset + data.count <= stage.size, data.count <= 512 * 1024 else { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
                do { let handle = try FileHandle.blockingForWriting(to: stage.file); try handle.blockingSeekToEnd(); try handle.blockingWrite(contentsOf: data); try handle.close() } catch { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
                stage.received += data.count; stage.expires = Date().addingTimeInterval(stageLifetime); stages[token] = stage
                armExpiry(expiry, work: work)
                return AgentPaneReply.success(["offset": stage.received])
            case .finish(let token):
                guard let stage = stages[token], stage.target.session == target.session, stage.received == stage.size else { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
                stages.removeValue(forKey: token)
                defer { try? FileManager.default.removeItem(at: stage.file) }
                do { let path = try await stage.target.host.putFile(sessionId: stage.target.session, name: stage.name, file: stage.file); return AgentPaneReply.success(["path": path]) } catch { return reply(AgentPaneFilePutFailure(error), machine: target.machine) }
            case .cancel(let token):
                if let stage = stages[token], stage.target.session == target.session {
                    stages.removeValue(forKey: token)
                    try? FileManager.default.removeItem(at: stage.file)
                }
                return AgentPaneReply.success()
            }
        }
    }

    /// Takes out the stages and batches expired by `now`; answers the expired stages' files and the next expiry.
    private static func purgeExpired(now: Date) -> (files: [URL], next: Date?) {
        let expired = stages.filter { $0.value.expires <= now }
        for token in expired.keys { stages.removeValue(forKey: token) }
        batches = batches.filter { $0.value.expires > now }
        return (expired.values.map(\.file), nextExpiry)
    }

    /// The earliest expiry date of a stage or a batch, nil when none is left.
    private static var nextExpiry: Date? {
        (stages.values.map(\.expires) + batches.values.map(\.expires)).min()
    }

    /// Points `expiry` at the earliest stage or batch expiry, or drops it when none is left
    /// (``AgentChatUploads/armStageExpiry(_:next:work:now:purge:)``).
    private static func armExpiry(_ expiry: MainDeadline, work: BackgroundWork) {
        AgentChatUploads.armStageExpiry(expiry, next: nextExpiry, work: work) { purgeExpired(now: $0) }
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

    /// The reply to the page's upload: each file put in turn with `put`, which answers its path on
    /// `machine`. A file past ``AgentPaneUpload/maximumPeerFileBytes`` is refused before any is sent.
    static func upload(_ files: [AgentPaneUpload], machine: String,
                       put: (_ name: String, _ data: Data) async throws -> String) async -> [String: Any] {
        guard files.allSatisfy({ $0.data.count <= AgentPaneUpload.maximumPeerFileBytes }) else {
            return AgentPaneReply.failure(code: "too_large", message: AgentPeerUploadStrings.tooLarge(machine))
        }
        var uploads: [[String: Any]] = []
        for file in files {
            do {
                let path = try await put(file.name, file.data)
                uploads.append(["name": file.name, "path": path])
            } catch {
                return reply(AgentPaneFilePutFailure(error), machine: machine)
            }
        }
        return AgentPaneReply.success(["uploads": uploads])
    }

    static func reply(_ failure: AgentPaneFilePutFailure, machine: String) -> [String: Any] {
        switch failure {
        // The page's own note: this chat takes no uploads (cloudUploads.ts `NOT_TAKEN`).
        case .unsupported: AgentPaneReply.failure(code: "unsupported", message: AgentPeerUploadStrings.failed(machine))
        case .tooLarge: AgentPaneReply.failure(code: "too_large", message: AgentPeerUploadStrings.tooLarge(machine))
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
}
