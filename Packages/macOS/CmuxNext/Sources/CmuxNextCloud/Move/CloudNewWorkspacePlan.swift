import Foundation

/// Where the Cloud toggle (#26062, `cloud.newWorkspacesInCloud`) sends a person's New Workspace:
/// nil keeps it on this Mac; otherwise a new Cloud machine of its own, starting in ``folder``
/// copied there, or in the machine's empty work folder when ``folder`` is nil.
public nonisolated struct CloudNewWorkspacePlan: Sendable, Equatable {
    /// The folder copied to the new machine (the working copy around the person's folder); nil
    /// starts in the machine's own empty folder.
    public let folder: CloudMoveFolder?

    /// What one copy of a folder answered (`cmux link sync push`'s JSON line).
    public struct CopyAnswer: Sendable, Equatable {
        public var ok: Bool, errorCode: String?, error: String?
        public init(ok: Bool, errorCode: String? = nil, error: String? = nil) {
            self.ok = ok
            self.errorCode = errorCode
            self.error = error
        }
    }

    /// Why a folder was not copied.
    public enum CopyFailure: Error, Equatable {
        /// The machine's cmux-tui is older than the copy needs (`machine_outdated`).
        case outdated
        /// Any other refusal, as the copy said it.
        case failed(String)
    }

    /// - Parameters:
    ///   - inCloud: `cloud.newWorkspacesInCloud`.
    ///   - inheritsFolder: `cloud.newWorkspaceFolder` is `inherit`, and this app can copy a folder
    ///     (without that the machine starts empty rather than fail after it exists).
    ///   - cwd: The folder the person works in on this Mac (the focused terminal's or chat's), if any.
    ///   - byPerson: A person's gesture; a script, the CLI or an agent keeps its workspace where it asked.
    ///   - namesMachineOrCommand: The run names a machine (it opens there) or a command (it runs here).
    public init?(inCloud: Bool, inheritsFolder: Bool, cwd: String?, byPerson: Bool, namesMachineOrCommand: Bool) {
        guard inCloud, byPerson, !namesMachineOrCommand else { return nil }
        // A home folder or the disk's root is never copied: the workspace starts empty instead.
        folder = inheritsFolder ? cwd.flatMap(CloudMoveFolder.init(chat:)).flatMap { $0.isTooBroad ? nil : $0 } : nil
    }

    /// The new workspace's name: the copied folder's, else none (the daemon names it).
    public var workspaceName: String? {
        folder.map { URL(fileURLWithPath: $0.root).lastPathComponent }
    }

    /// Copies `folder` under the first of `workRoots` the machine lets it write (an image without
    /// the work user refuses its home with `fs.permission_denied`) through `push(remote)`.
    /// Returns the copied folder and the person's folder in it, on the machine.
    public static func copy(_ folder: CloudMoveFolder, workRoots: [String],
                            push: (String) async throws -> CopyAnswer) async throws -> (folder: String, chat: String) {
        var last = CopyAnswer(ok: false)
        for root in workRoots {
            let remote = folder.remote(under: root)
            last = try await push(remote.folder)
            if last.ok { return remote }
            guard last.errorCode == "fs.permission_denied" else { break }
        }
        if last.errorCode == "machine_outdated" { throw CopyFailure.outdated }
        throw CopyFailure.failed(last.error ?? last.errorCode ?? "")
    }
}
