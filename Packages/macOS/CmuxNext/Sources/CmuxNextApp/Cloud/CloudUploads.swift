import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation

/// Files the person drops or pastes into a chat moved to a Cloud machine (cmuxterm-hq#1874 slice 6)
/// that the composer can't attach: the page sends their bytes (``AgentPaneUpload``), and only for a
/// live moved chat's own tab, with a real gesture in its pane, the app writes them under this Mac's
/// temporary `cmux-pastes` folder (owner-only), runs `cmux link access upload` for the chat's machine
/// and work root, deletes its copy, and answers where each went on the machine. Nothing is uploaded
/// from anywhere else on this Mac, and the machine can't start an upload.
@MainActor
final class CloudUploads {
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

    /// A staged file's transfer: the CLI's answer, the file's name, and where it went.
    private struct Delivery: Sendable {
        var answer: CloudAccessCLI.Answer
        var name: String
        var socket: String?
        var binary: URL
        var remoteRoot: String
    }

    /// This Mac's staged Cloud uploads: files of any size, in `cmux-pastes` until the machine has them.
    private let stages = AgentPaneStagedUploads<Target>(owner: "CloudUploads.stageExpiry")

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
        guard !files.isEmpty else { return AgentPaneReply.failure(code: "upload_failed", message: CloudUploadStrings.failed) }
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
            // The CLI's message names the files: private. A refusal keeps its code for the page.
            services.cloud.logger.error("cloud upload: \(answer.errorCode ?? "", privacy: .public) \(answer.error ?? "", privacy: .private)")
            return AgentPaneReply.failure(code: answer.errorCode ?? "upload_failed", message: CloudUploadStrings.failed)
        }
        let uploads = zip(files, answer.uploaded).map { file, path -> [String: Any] in ["name": file.name, "path": path] }
        return AgentPaneReply.success(["uploads": uploads])
    }

    private static func reply(_ answer: CloudAccessCLI.Answer, names: [String], services: AppServices) -> [String: Any] {
        guard answer.ok, answer.uploaded.count == names.count else {
            services.cloud.logger.error("cloud upload: \(answer.errorCode ?? "", privacy: .public) \(answer.error ?? "", privacy: .private)")
            return AgentPaneReply.failure(code: answer.errorCode ?? "upload_failed", message: CloudUploadStrings.failed)
        }
        return AgentPaneReply.success(["uploads": zip(names, answer.uploaded).map { ["name": $0.0, "path": $0.1] }])
    }

    private func stage(_ request: AgentPaneUploadStageRequest, tab: String, session: String, services: AppServices) async -> [String: Any] {
        let failed = AgentPaneReply.failure(code: "upload_failed", message: CloudUploadStrings.failed)
        await stages.purge(work: services.work)
        let owns = { (staged: Target) in staged.chat.session == session }
        // Every step but a cancel needs the tab to show the chat still.
        let current = { Self.target(tab: tab, services: services).flatMap { $0.chat.session == session ? $0 : nil } }
        switch request {
        case .begin(let name, let size, let batchToken, let manifest):
            guard let found = current() else { return failed }
            let target: Target
            if let batchToken {
                guard let batch = stages.batchTarget(batchToken, name: name, size: size), owns(batch),
                      found.machine.machineID == batch.machine.machineID, found.remoteRoot == batch.remoteRoot else { return failed }
                target = batch
            } else { target = found }
            if let refusal = Self.beginRefusal(name: name, size: size, manifest: batchToken == nil ? manifest : nil) { return refusal }
            guard let pastes = Self.pastes else { return failed }
            let begun = stages.begin(name: name, size: size, batchToken: batchToken, manifest: manifest, target: target, work: services.work) { token in
                let folder = pastes.appendingPathComponent("staged-" + token, isDirectory: true)
                let file = folder.appendingPathComponent(name, isDirectory: false)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    return nil
                }
                return (file, folder)
            }
            guard let begun else { return failed }
            var response: [String: Any] = ["token": begun.token, "size": size, "chunkSize": AgentPaneStagedUploads<Target>.chunkBytes]
            if let batch = begun.batchToken { response["batchToken"] = batch }
            return AgentPaneReply.success(response)
        case .chunk(let token, let offset, let data):
            guard current() != nil, let received = stages.chunk(token, offset: offset, data: data, owns: owns, work: services.work) else { return failed }
            return AgentPaneReply.success(["offset": received])
        case .finish(let token):
            guard current() != nil else { return failed }
            let done = await stages.finish(token, owns: owns, work: services.work, transfer: { staged -> Delivery in
                let target = staged.target
                guard let socket = await target.machine.daemon.connection?.endpoint?.socketPath else {
                    return Delivery(answer: CloudAccessCLI.Answer(ok: false, errorCode: "link_error"), name: staged.name, socket: nil, binary: target.binary, remoteRoot: target.remoteRoot)
                }
                let answer = try? await CloudAccessCLI(binary: target.binary).upload(socket: socket, remoteRoot: target.remoteRoot, files: [staged.file.path])
                return Delivery(answer: answer ?? CloudAccessCLI.Answer(ok: false, errorCode: "upload_failed"), name: staged.name, socket: socket, binary: target.binary, remoteRoot: target.remoteRoot)
            }, undo: { done in
                // A cancel after the file arrived (the chip's x as the answer comes back) removes it from the machine.
                guard done.answer.ok, !done.answer.uploadIDs.isEmpty, let socket = done.socket else { return nil }
                return {
                    try? await CloudAccessCLI(binary: done.binary).removeUploads(socket: socket, remoteRoot: done.remoteRoot, ids: done.answer.uploadIDs)
                }
            })
            guard let done else { return failed }
            return Self.reply(done.answer, names: [done.name], services: services)
        case .cancel(let token):
            await stages.cancel(token, owns: owns, work: services.work)
            return AgentPaneReply.success()
        }
    }

    /// The reply refusing a staged upload's begin of `name`, `size` bytes, that starts the batch
    /// `manifest` (nil for a lone file or a later file of a batch), or nil when the begin is well formed.
    /// No size is too large: a file or a batch of any size is taken.
    static func beginRefusal(name: String, size: Int, manifest: [AgentPaneUploadBatchEntry]?) -> [String: Any]? {
        AgentPaneStagedUploads<Target>.acceptsBegin(name: name, size: size, manifest: manifest)
            ? nil : AgentPaneReply.failure(code: "upload_failed", message: CloudUploadStrings.failed)
    }

    /// Writes each file owner-only to `folder/<index>/<name>` (its own folder, so two files may share
    /// a name), with `cmux-pastes` and `folder` owner-only too; the paths, in order.
    private nonisolated static func write(_ files: [AgentPaneUpload], in folder: URL) throws -> [String] {
        let manager = FileManager.default, owner: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try manager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: owner)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: owner)
        return try files.enumerated().map { index, file in
            let parent = folder.appendingPathComponent(String(index), isDirectory: true)
            try manager.createDirectory(at: parent, withIntermediateDirectories: false, attributes: owner)
            let url = parent.appendingPathComponent(file.name, isDirectory: false)
            guard manager.createFile(atPath: url.path, contents: file.data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return url.path
        }
    }
}

/// A Cloud chat upload's failure text, shown in the composer. Keys live in Resources/Cloud.xcstrings.
enum CloudUploadStrings {
    /// The bundle that holds `Resources/Cloud.xcstrings` (this module's), for tests.
    static var bundle: Bundle { .module }
    static var failed: String {
        String(localized: "cloud.upload.failed", defaultValue: "Couldn't send the file to the Cloud machine.", table: "Cloud", bundle: .module)
    }
}
