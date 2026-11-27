import AppKit
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudPlace
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// Files the person drops or pastes into a chat moved to a Cloud machine (cmuxterm-hq#1874 slice 6),
/// or started there with no folder, that the composer can't attach: the page sends their bytes (``AgentPaneUpload``), and only for a
/// live moved chat's own tab, with a real gesture in its pane, the app writes them under this Mac's
/// temporary `cmux-pastes` folder (owner-only), runs `cmux link access upload` for the chat's machine
/// and work root, deletes its copy, and answers where each went on the machine. Nothing is uploaded
/// from anywhere else on this Mac, and the machine can't start an upload.
@MainActor
final class CloudUploads {
    nonisolated static var pastes: URL? { AgentPaneCloudAttachments.pastes }

    /// Where one tab's upload goes: the chat's session, its machine and its work root.
    struct Target {
        var session: String
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

    /// The upload for chat tab `tab`, nil unless it is a live moved chat, or a folderless Cloud start's
    /// chat, on a connected machine. The upload looks the chat up again when it runs.
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

    /// Where chat tab `tab`'s files go on its Cloud machine (also Sources > Add Folder, ``addFolder(tab:session:services:)``).
    static func target(tab: String, services: AppServices) -> Target? {
        guard !services.machines.isFeatureDisabled(.cloud), let binary = services.cloud.move.cli, pastes != nil else { return nil }
        for chat in services.cloud.movedChats.all() where chat.broughtBack == nil {
            guard let machine = services.machines.session(chat.machineID), machine.daemon.connection != nil,
                  CloudAccessAsks.tab(of: chat, on: machine, services: services) == tab else { continue }
            guard let root = services.cloud.move.workRoot(of: chat.remoteFolder) else { return nil }
            return Target(session: chat.session, machine: machine, remoteRoot: root, binary: binary)
        }
        // A folderless Cloud start's chat (CloudStartChat `runHome`): into the first work root, as its first send.
        guard let session = services.agentTabs.session(of: tab), let root = services.cloud.move.workRoots.first,
              let machine = services.machines.cloud.first(where: { machine in
                  machine.daemon.connection != nil && AgentTabStore.registryHost(of: machine.daemon)
                      .map { machine.daemon.store.holdsChat(tab: services.agentTabs.resolve(tab), host: $0, session: session) } == true
              }) else { return nil }
        return Target(session: session, machine: machine, remoteRoot: root, binary: binary)
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
            paths = try await Task.detached { try AgentPaneCloudAttachments.write(files, in: folder) }.value
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
        return reply(answer, names: files.map(\.name), services: services)
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
        let owns = { (staged: Target) in staged.session == session }
        // Every step but a cancel needs the tab to show the chat still.
        let current = { Self.target(tab: tab, services: services).flatMap { $0.session == session ? $0 : nil } }
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
            guard current() != nil, let received = await stages.chunk(token, offset: offset, data: data, owns: owns, work: services.work) else { return failed }
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
}

/// A Cloud chat upload's failure text, shown in the composer. Keys live in Resources/Cloud.xcstrings.
enum CloudUploadStrings {
    /// The bundle that holds `Resources/Cloud.xcstrings` (this module's), for tests.
    static var bundle: Bundle { .module.inAppLanguage }
    static var failed: String {
        String(localized: "cloud.upload.failed", defaultValue: "Couldn't send the file to the Cloud machine.", table: "Cloud", bundle: .module.inAppLanguage)
    }
}

/// Sources > Add Folder on a running Cloud chat (`cloud.folder.add`, setting `cloud.addFolderLive`,
/// on by default). Leo, 2026-11-25: "mostly just the one you selected, right? then you can add more
/// folders and files/select more as you go potentially". The person picks a Mac folder; one Rust
/// call (`cmux link access grant --attach`) refuses what may never go (outside the home folder, dot
/// and credential folders, ~/Library), copies it read-only to the chat's machine, skipping secret
/// files, and puts the copy among the chat's folders there (`chat-folder-add`, acpmux
/// `_acpmux/set_directories`, between turns). The chat draws the line ("Added ~/x as /vm/path")
/// from acpmux's record; a failure comes back as the reply's reason, which the page shows in the
/// chat, and nothing is added.
extension CloudUploads {
    static func addFolderIsOn(_ services: AppServices) -> Bool {
        CloudNewWorkspaceSetting().addFolderLive(in: services.settings?.snapshot.root ?? .object([:]))
    }

    /// The person's Add Folder click on chat tab `tab` showing `session`: `{applied, path, from}`,
    /// `applied` "cancelled" when no folder was picked.
    static func addFolder(tab: String, session: String, services: AppServices) async throws -> [String: Any] {
        guard addFolderIsOn(services) else { throw addFolderFailure(addFolderOff) }
        guard let target = target(tab: tab, services: services), target.session == session else {
            throw addFolderFailure(addFolderUnavailable)
        }
        guard let folder = await NewTabPage.chooseFolder(in: NSApp.keyWindow) else { return ["applied": "cancelled"] }
        let started = ContinuousClock.now
        guard let socket = await target.machine.daemon.connection?.endpoint?.socketPath else { throw addFolderFailure(addFolderUnavailable) }
        let answer: CloudAccessCLI.Answer
        do {
            answer = try await CloudAccessCLI(binary: target.binary).grantAttached(
                socket: socket, machine: target.machine.machineID, session: session, remoteRoot: target.remoteRoot, folder: folder.path)
        } catch {
            answer = CloudAccessCLI.Answer(ok: false, error: String(describing: error))
        }
        let logger = services.cloud.logger
        guard answer.ok, let path = answer.attachedPath else {
            logger.error("cloud folder add: session \(session, privacy: .public) failed \(answer.errorCode ?? "", privacy: .public)")
            // The CLI's reason names what was refused and why ("… cannot be shared: credential folders are never shared").
            throw addFolderFailure(answer.error ?? addFolderFailed)
        }
        let applied = answer.attachedApplied ?? "now"
        let took = started.duration(to: .now).components
        let ms = Int(took.seconds) * 1000 + Int(took.attoseconds / 1_000_000_000_000_000)
        logger.info("cloud folder add: session \(session, privacy: .public) applied \(applied, privacy: .public) in \(ms) ms")
        return ["applied": applied, "path": path, "from": folder.path]
    }

    private static func addFolderFailure(_ message: String) -> NSError {
        NSError(domain: "cloud.folder.add", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // Add Folder's failure texts, shown in the chat.
    private static var addFolderOff: String {
        String(localized: "cloud.folderAdd.off", defaultValue: "Adding folders to Cloud chats is turned off in Settings.", table: "Cloud", bundle: .module.inAppLanguage)
    }
    private static var addFolderUnavailable: String {
        String(localized: "cloud.folderAdd.unavailable", defaultValue: "This chat's Cloud machine isn't connected.", table: "Cloud", bundle: .module.inAppLanguage)
    }
    private static var addFolderFailed: String {
        String(localized: "cloud.folderAdd.failed", defaultValue: "The folder couldn't be added.", table: "Cloud", bundle: .module.inAppLanguage)
    }
}
