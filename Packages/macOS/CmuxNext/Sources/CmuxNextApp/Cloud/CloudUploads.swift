import CmuxNextAgentPane
import Foundation

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
    static var failed: String {
        String(localized: "cloud.upload.failed", defaultValue: "Couldn't send the file to the Cloud machine.", table: "Cloud", bundle: .module)
    }
    static var refused: String {
        String(localized: "cloud.upload.refused", defaultValue: "This Mac won't send that file to the Cloud machine.", table: "Cloud", bundle: .module)
    }
}
