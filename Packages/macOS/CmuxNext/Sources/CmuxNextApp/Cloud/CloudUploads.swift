import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation
import CmuxNextCompat

/// Files the person drops or pastes into a chat moved to a Cloud machine (cmuxterm-hq#1874 slice 6)
/// that the composer can't attach: the page sends their bytes (``AgentPaneUpload``), and only for a
/// live moved chat's own tab, with a real gesture in its pane, the app writes them under this Mac's
/// temporary `cmux-pastes` folder (owner-only), runs `cmux link access upload` for the chat's machine
/// and work root, deletes its copy, and answers where each went on the machine. Nothing is uploaded
/// from anywhere else on this Mac, and the machine can't start an upload.
@MainActor
final class CloudUploads {
    /// Cloud paste uploads retain an independent abuse guard even though local and peer uploads
    /// stream up to the native transport's larger limit.
    nonisolated static let maximumFileBytes = 32 * 1024 * 1024
    nonisolated static let maximumTotalBytes = 64 * 1024 * 1024
    nonisolated static let stageChunkBytes = 512 * 1024
    private static let stageLifetime: TimeInterval = 10 * 60
    /// `cmux-pastes` in the temporary folder the upload CLI (a child of this app, with its
    /// environment) resolves: `TMPDIR`. Nil without one (the CLI would look elsewhere): no upload.
    nonisolated static var pastes: URL? {
        guard let temporary = ProcessInfo.processInfo.environment["TMPDIR"], temporary.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: temporary, isDirectory: true).appendingPathComponent("cmux-pastes", isDirectory: true)
    }

    /// Where one tab's upload goes: the moved chat's machine and its work root.
    private struct Target {
        var chat: CloudMovedChats.Entry
        var machine: CloudMachineSession
        var remoteRoot: String
        var binary: URL
    }

    private struct Stage {
        var target: Target
        var folder: URL
        var file: URL
        var name: String
        var size: Int
        var received: Int
        var expires: Date
    }

    private var stages: [String: Stage] = [:]
    private struct Batch { var target: Target; var remaining: [AgentPaneUploadBatchEntry]; var expires: Date }
    private var batches: [String: Batch] = [:]
    /// One deadline for the earliest stage expiry, so an abandoned stage's folder is removed
    /// without a sleeping task per stage (plans/cmux-next/idle-wakeups.md). Nobody waits on it:
    /// the background class, flexible.
    private let expiryTimer: MainDeadline

    /// - Parameter deadlines: The app's one deadline scheduler.
    init(deadlines: MainDeadlineScheduler) {
        expiryTimer = MainDeadline(owner: "CloudUploads.stageExpiry", workClass: .background, scheduler: deadlines)
    }

    /// The upload for chat tab `tab`, nil unless it is a live moved chat on a connected machine. The
    /// upload looks the chat up again when it runs.
    func uploader(tab: String, services: AppServices) -> AgentPaneUploader? {
        guard Self.target(tab: tab, services: services) != nil else { return nil }
        return { [weak services] files in
            guard let services, let target = Self.target(tab: tab, services: services) else {
                return AgentPaneReply.failure(code: "unsupported", message: CloudUploadStrings.failed)
            }
            return await Self.upload(files, to: target, services: services)
        }
    }

    func stager(tab: String, services: AppServices) -> AgentPaneUploadStager? {
        guard Self.target(tab: tab, services: services) != nil else { return nil }
        return { [weak self, weak services] request, session in
            guard let self, let services else { return AgentPaneReply.failure(code: "unsupported", message: CloudUploadStrings.failed) }
            // A staged upload names its chat session, as the peer stager requires.
            guard let session else { return AgentPaneReply.failure(code: "upload_failed", message: CloudUploadStrings.failed) }
            return await self.stage(request, tab: tab, session: session, services: services)
        }
    }

    private static func target(tab: String, services: AppServices) -> Target? {
        guard !services.machines.isFeatureDisabled(.cloud), let binary = services.cloud.move.cli, pastes != nil else { return nil }
        for chat in services.cloud.movedChats.all() where chat.broughtBack == nil {
            guard let machine = services.machines.session(chat.machineID), machine.daemon.connection != nil,
                  CloudAccessAsks.tab(of: chat, on: machine, services: services) == tab,
                  let root = CloudAccessAsks.remoteRoot(chat.remoteFolder, roots: services.cloud.move.workRoots) else { continue }
            return Target(chat: chat, machine: machine, remoteRoot: root, binary: binary)
        }
        return nil
    }

    private static func upload(_ files: [AgentPaneUpload], to target: Target, services: AppServices) async -> [String: Any] {
        let total = files.reduce(into: 0) { $0 += $1.data.count }
        guard !files.isEmpty, total <= maximumTotalBytes,
              files.allSatisfy({ $0.data.count <= maximumFileBytes }) else {
            return AgentPaneReply.failure(code: "upload_refused", message: CloudUploadStrings.refused)
        }
        guard let socket = await target.machine.daemon.connection?.endpoint?.socketPath, let pastes else {
            return AgentPaneReply.failure(code: "link_error", message: CloudUploadStrings.failed)
        }
        let folder = pastes.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths: [String]
        do {
            paths = try await Task.detached { try CloudUploads.write(files, in: folder) }.value
        } catch {
            // The error's domain and code only: its description can name the file.
            let failure = error as NSError
            services.cloud.logger.error("cloud upload: could not write the pasted files: \(failure.domain, privacy: .public) \(failure.code)")
            return AgentPaneReply.failure(code: "upload_failed", message: CloudUploadStrings.failed)
        }
        let answer: CloudAccessCLI.Answer
        do {
            answer = try await CloudAccessCLI(binary: target.binary).upload(socket: socket, remoteRoot: target.remoteRoot, files: paths)
        } catch {
            answer = CloudAccessCLI.Answer(ok: false, error: String(describing: error))
        }
        guard answer.ok, answer.uploaded.count == files.count else {
            // The CLI's message names the files: private.
            services.cloud.logger.error("cloud upload: \(answer.errorCode ?? "", privacy: .public) \(answer.error ?? "", privacy: .private)")
            let refused = answer.errorCode == "upload_refused"
            return AgentPaneReply.failure(code: answer.errorCode ?? "upload_failed", message: refused ? CloudUploadStrings.refused : CloudUploadStrings.failed)
        }
        let uploads = zip(files, answer.uploaded).map { file, path -> [String: Any] in ["name": file.name, "path": path] }
        return AgentPaneReply.success(["uploads": uploads])
    }

    private static func reply(_ answer: CloudAccessCLI.Answer, names: [String], services: AppServices) -> [String: Any] {
        guard answer.ok, answer.uploaded.count == names.count else {
            services.cloud.logger.error("cloud upload: \(answer.errorCode ?? "", privacy: .public) \(answer.error ?? "", privacy: .private)")
            let refused = answer.errorCode == "upload_refused"
            return AgentPaneReply.failure(code: answer.errorCode ?? "upload_failed", message: refused ? CloudUploadStrings.refused : CloudUploadStrings.failed)
        }
        return AgentPaneReply.success(["uploads": zip(names, answer.uploaded).map { ["name": $0.0, "path": $0.1] }])
    }

    private func stage(_ request: AgentPaneUploadStageRequest, tab: String, session: String, services: AppServices) async -> [String: Any] {
        purgeStages()
        switch request {
        case .begin(let name, let size, let batchToken, let manifest):
            let target: Target
            if let batchToken {
                guard let batch = batches[batchToken], batch.target.chat.session == session,
                      batch.expires > Date(), batch.remaining.first?.name == name, batch.remaining.first?.size == size,
                      let current = Self.target(tab: tab, services: services), current.chat.session == batch.target.chat.session,
                      current.machine.machineID == batch.target.machine.machineID, current.remoteRoot == batch.target.remoteRoot else { return AgentPaneReply.failure(code: "upload_failed", message: CloudUploadStrings.failed) }
                target = batch.target
                batches[batchToken] = Batch(target: batch.target, remaining: Array(batch.remaining.dropFirst()), expires: Date().addingTimeInterval(Self.stageLifetime))
            } else {
                guard let found = Self.target(tab: tab, services: services), found.chat.session == session else { return AgentPaneReply.failure(code: "upload_failed", message: CloudUploadStrings.failed) }
                target = found
            }
            guard target.chat.session == session,
                  size <= Self.maximumFileBytes else { return AgentPaneReply.failure(code: "upload_refused", message: CloudUploadStrings.refused) }
            let batchID: String?
            if let manifest, batchToken == nil {
                guard manifest.first?.name == name, manifest.first?.size == size,
                      manifest.allSatisfy({ $0.size >= 0 && $0.size <= Self.maximumFileBytes }),
                      manifest.reduce(0) { $0 + $1.size } <= Self.maximumTotalBytes else { return AgentPaneReply.failure(code: "upload_refused", message: CloudUploadStrings.refused) }
                let newBatchID = UUID().uuidString.lowercased()
                batchID = newBatchID
                batches[newBatchID] = Batch(target: target, remaining: Array(manifest.dropFirst()), expires: Date().addingTimeInterval(Self.stageLifetime))
            } else { batchID = batchToken }
            let used = stages.values.filter { $0.target.chat.session == session }.reduce(0) { $0 + $1.size }
            guard used + size <= Self.maximumTotalBytes, let pastes = Self.pastes else { return AgentPaneReply.failure(code: "upload_refused", message: CloudUploadStrings.refused) }
            let token = UUID().uuidString.lowercased(), folder = pastes.appendingPathComponent("staged-" + token, isDirectory: true)
            let file = folder.appendingPathComponent(name, isDirectory: false)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            } catch { return AgentPaneReply.failure(code: "upload_failed", message: CloudUploadStrings.failed) }
            stages[token] = Stage(target: target, folder: folder, file: file, name: name, size: size, received: 0, expires: Date().addingTimeInterval(Self.stageLifetime))
            armExpiry()
            var response: [String: Any] = ["token": token, "size": size, "chunkSize": Self.stageChunkBytes]
            if let batchID { response["batchToken"] = batchID }
            return AgentPaneReply.success(response)
        case .chunk(let token, let offset, let data):
            guard var stage = stages[token], stage.target.chat.session == session, stage.received == offset,
                  let current = Self.target(tab: tab, services: services), current.chat.session == stage.target.chat.session,
                  data.count <= Self.stageChunkBytes, offset + data.count <= stage.size else { return AgentPaneReply.failure(code: "upload_failed", message: CloudUploadStrings.failed) }
            do {
                let handle = try FileHandle.blockingForWriting(to: stage.file)
                try handle.blockingSeekToEnd(); try handle.blockingWrite(contentsOf: data); try handle.close()
            } catch { return AgentPaneReply.failure(code: "upload_failed", message: CloudUploadStrings.failed) }
            stage.received += data.count; stage.expires = Date().addingTimeInterval(Self.stageLifetime); stages[token] = stage
            armExpiry()
            return AgentPaneReply.success(["offset": stage.received])
        case .finish(let token):
            guard let stage = stages[token], stage.target.chat.session == session,
                  let current = Self.target(tab: tab, services: services), current.chat.session == stage.target.chat.session,
                  stage.received == stage.size else { return AgentPaneReply.failure(code: "upload_failed", message: CloudUploadStrings.failed) }
            stages.removeValue(forKey: token)
            defer { try? FileManager.default.removeItem(at: stage.folder) }
            guard let socket = await stage.target.machine.daemon.connection?.endpoint?.socketPath else { return AgentPaneReply.failure(code: "link_error", message: CloudUploadStrings.failed) }
            let answer = (try? await CloudAccessCLI(binary: stage.target.binary).upload(socket: socket, remoteRoot: stage.target.remoteRoot, files: [stage.file.path])) ?? CloudAccessCLI.Answer(ok: false, errorCode: "upload_failed")
            return Self.reply(answer, names: [stage.name], services: services)
        case .cancel(let token):
            guard let stage = stages[token], stage.target.chat.session == session else { return AgentPaneReply.success() }
            stages.removeValue(forKey: token)
            try? FileManager.default.removeItem(at: stage.folder); return AgentPaneReply.success()
        }
    }

    private func purgeStages() {
        let expired = stages.filter { $0.value.expires < Date() }.map(\.key)
        for token in expired {
            if let stage = stages.removeValue(forKey: token) { try? FileManager.default.removeItem(at: stage.folder) }
        }
        batches = batches.filter { $0.value.expires >= Date() }
    }

    /// Arms the deadline for the earliest live stage's expiry; nothing pending when no stage is left.
    private func armExpiry() {
        guard let next = stages.values.map(\.expires).min() else { expiryTimer.cancel(); return }
        expiryTimer.schedule(after: .seconds(max(1, next.timeIntervalSinceNow))) { [weak self] in
            guard let self else { return }
            purgeStages()
            armExpiry()
        }
    }

    /// Writes each file owner-only to `folder/<index>/<name>` (its own folder, so two files may share
    /// a name), with `cmux-pastes` and `folder` owner-only too; the paths, in order.
    private nonisolated static func write(_ files: [AgentPaneUpload], in folder: URL) throws -> [String] {
        let owner: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.checked.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: owner)
        try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: false, attributes: owner)
        return try files.enumerated().map { index, file in
            let parent = folder.appendingPathComponent(String(index), isDirectory: true)
            try FileManager.checked.createDirectory(at: parent, withIntermediateDirectories: false, attributes: owner)
            let url = parent.appendingPathComponent(file.name, isDirectory: false)
            guard FileManager.checked.createFile(atPath: url.path, contents: file.data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return url.path
        }
    }
}

/// A Cloud chat upload's failure text, shown in the composer. Keys live in Resources/Cloud.xcstrings.
enum CloudUploadStrings {
    static var failed: String {
        String(localized: "cloud.upload.failed", defaultValue: "Couldn't send the file to the Cloud machine.", table: "Cloud", bundle: .module)
    }
    static var refused: String {
        String(localized: "cloud.upload.refused", defaultValue: "This Mac won't send that file to the Cloud machine.", table: "Cloud", bundle: .module)
    }
}
