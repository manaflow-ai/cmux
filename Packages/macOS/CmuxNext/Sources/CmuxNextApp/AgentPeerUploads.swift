import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextWakeups
import Foundation

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
    private struct Stage {
        var target: Target; var file: URL; var name: String; var size: Int; var received: Int; var expires: Date
        var batchToken: String?
        var finish: Task<Result<String, Error>, Never>?
        var expiry: Task<Void, Never>?
        var cleanup: Task<Void, Never>?
    }
    private struct Batch { var session: String; var authorization: AgentPaneUploadBatch; var expiry: Task<Void, Never>? }
    private static var stages: [String: Stage] = [:]
    private static var batches: [String: Batch] = [:]
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
        return { request, session in
            let expired = batches.filter { !$0.value.authorization.isAlive() }.map(\.key)
            for token in expired { batches.removeValue(forKey: token)?.expiry?.cancel() }
            guard session == target.session else { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
            switch request {
            case .begin(let name, let size, let batchToken, let manifest):
                if let batchToken {
                    guard let batch = batches[batchToken], batch.session == target.session,
                          batch.authorization.accepts(name: name, size: size) else { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
                }
                // No size is too large here: a file or a batch of any size is staged; only the peer may refuse one.
                guard size >= 0 else { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
                if let manifest {
                    guard manifest.first?.name == name, manifest.first?.size == size,
                          manifest.allSatisfy({ $0.size >= 0 }) else { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
                }
                let token = UUID().uuidString.lowercased(), file = FileManager.default.temporaryDirectory.appending(path: "cmux-peer-staged-" + token + "-" + name)
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
                let batchID: String?
                if let batchToken {
                    batchID = batchToken
                } else if let manifest, manifest.count > 1 {
                    let id = UUID().uuidString.lowercased()
                    batches[id] = Batch(session: target.session, authorization: AgentPaneUploadBatch(manifest))
                    batchID = id
                } else { batchID = nil }
                if let batchID {
                    batches[batchID]?.authorization.begin(name: name, size: size, stage: token)
                    armBatchExpiry(batchID)
                }
                stages[token] = Stage(target: target, file: file, name: name, size: size, received: 0, expires: Date().addingTimeInterval(10 * 60), batchToken: batchID, finish: nil)
                armStageExpiry(token, work: services.work)
                var reply: [String: Any] = ["token": token, "size": size, "chunkSize": 512 * 1024]
                if let batchID { reply["batchToken"] = batchID }
                return AgentPaneReply.success(reply)
            case .chunk(let token, let offset, let data):
                guard var stage = stages[token], stage.target.session == target.session, stage.finish == nil, stage.cleanup == nil, stage.received == offset, data.count <= stage.size - offset, data.count <= 512 * 1024 else { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
                do { let handle = try FileHandle(forWritingTo: stage.file); try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close() } catch { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
                stage.received += data.count; stage.expires = Date().addingTimeInterval(10 * 60); stages[token] = stage
                armStageExpiry(token, work: services.work)
                return AgentPaneReply.success(["offset": stage.received])
            case .finish(let token):
                guard var stage = stages[token], stage.target.session == target.session, stage.received == stage.size, stage.finish == nil, stage.cleanup == nil else { return AgentPaneReply.failure(code: "upload_failed", message: AgentPeerUploadStrings.failed(target.machine)) }
                stage.expiry?.cancel()
                stage.expiry = nil
                let source = stage
                let task = Task { () -> Result<String, Error> in
                    let result: Result<String, Error>
                    do {
                        result = .success(try await source.target.host.putFile(sessionId: source.target.session, name: source.name, file: source.file))
                    } catch {
                        result = .failure(error)
                    }
                    await removeStage(token, work: services.work)
                    return result
                }
                stage.finish = task
                stages[token] = stage
                let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
                switch result {
                case .success(let path): return AgentPaneReply.success(["path": path])
                case .failure(let error): return reply(AgentPaneFilePutFailure(error), machine: target.machine)
                }
            case .cancel(let token):
                if let stage = stages[token], stage.target.session == target.session {
                    if let task = stage.finish {
                        task.cancel()
                        _ = await task.value
                        return AgentPaneReply.success()
                    }
                    await removeStage(token, work: services.work)
                }
                return AgentPaneReply.success()
            }
        }
    }

    /// Each stage owns one expiry task, replaced by a chunk and stopped before transfer or cleanup.
    private static func armStageExpiry(_ token: String, work: BackgroundWork) {
        stages[token]?.expiry?.cancel()
        stages[token]?.expiry = Task { @MainActor in
            // wakeup-allow: one owned stage deadline, cancelled on refresh, finish or cancel.
            do { try await Task.sleep(for: .seconds(10 * 60)) } catch { return }
            if stages[token]?.finish == nil { await removeStage(token, work: work) }
        }
    }

    private static func removeStage(_ token: String, work: BackgroundWork) async {
        if let cleanup = stages[token]?.cleanup { await cleanup.value; return }
        guard let stage = stages[token] else { return }
        stage.expiry?.cancel()
        let file = stage.file
        // task-owner: one awaited cleanup, independent of the cancelled transfer; the file lane
        // performs the unlink off main and blockShutdown retains it until that unlink completes.
        let cleanup = Task(priority: WorkPriority.userBlocking.taskPriority) { @MainActor in
            _ = try? await work.run(.userBlocking, mayBlock: .files, shutdown: .blockShutdown) {
                try? FileManager.checked.removeItem(at: file)
            }
            stages.removeValue(forKey: token)
            if let batchToken = stage.batchToken {
                batches[batchToken]?.authorization.release(stage: token)
                if batches[batchToken]?.authorization.isComplete == true {
                    batches.removeValue(forKey: batchToken)?.expiry?.cancel()
                } else { armBatchExpiry(batchToken) }
            }
        }
        stages[token]?.cleanup = cleanup
        await cleanup.value
    }

    private static func armBatchExpiry(_ token: String) {
        batches[token]?.expiry?.cancel()
        batches[token]?.expiry = nil
        guard let deadline = batches[token]?.authorization.abandonmentDeadline else { return }
        batches[token]?.expiry = Task { @MainActor in
            // wakeup-allow: only an ownerless batch expires; a stage cancels this deadline until cleanup.
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
            if batches[token]?.authorization.isAlive() == false { batches.removeValue(forKey: token) }
        }
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
    /// `machine`. A file of any size is sent; only the peer may refuse one as too large.
    static func upload(_ files: [AgentPaneUpload], machine: String,
                       put: (_ name: String, _ data: Data) async throws -> String) async -> [String: Any] {
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
