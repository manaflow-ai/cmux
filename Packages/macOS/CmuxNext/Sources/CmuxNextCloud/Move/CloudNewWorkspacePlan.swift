import CmuxNextCompat
public import CmuxNextWakeups
import Foundation

/// Where the Cloud toggle (#26062, `cloud.newWorkspacesInCloud`) sends a person's New Workspace:
/// nil keeps it on this Mac; otherwise a new Cloud machine of its own, starting in the person's
/// folder copied there (``folder(work:)``), or in the machine's empty work folder.
/// Deciding reads no disk, so it fits the New Workspace action's turn; the folder is resolved later.
public nonisolated struct CloudNewWorkspacePlan: Sendable, Equatable {
    /// The person's folder when Current Folder applies; nil starts in the machine's own empty folder.
    public let source: String?

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

    /// Where a planned New Workspace goes. A machine costs money, so one is asked for only where its
    /// progress, Cancel and Retry show (a window), and only when Cloud can make it; otherwise the
    /// workspace opens on this Mac and the person is told why, never silently.
    public enum Route: Sendable, Equatable {
        case cloud
        case thisMac(Refusal)
    }

    /// Why a New Workspace the toggle would send to Cloud opened on this Mac instead.
    public enum Refusal: Sendable, Equatable {
        /// Cloud cannot run in this build or for this account (the reason as Cloud says it).
        case unavailable(String)
        case signedOut
        /// No open window to show the new machine's progress in (Cmd-N with every window closed).
        case noWindow
    }

    /// What New Workspace does after asking the toggle.
    public enum Outcome: Sendable, Equatable {
        /// A new machine's creation started, showing in the window: New Workspace makes nothing here.
        case started
        /// New Workspace opens on this Mac. `notice`, when the toggle is on, says why it is not in
        /// Cloud; New Workspace shows it once the workspace opens.
        case thisMac(notice: String?)
    }

    public static func route(unavailableReason: String?, signedIn: Bool, hasWindow: Bool) -> Route {
        if let unavailableReason { return .thisMac(.unavailable(unavailableReason)) }
        if !signedIn { return .thisMac(.signedOut) }
        if !hasWindow { return .thisMac(.noWindow) }
        return .cloud
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
        source = inheritsFolder ? cwd : nil
    }

    /// The folder copied to the machine, read on `work`'s files lane (never the main thread). Throws
    /// when the creation was cancelled meanwhile, so nothing more is made on the machine.
    public func folder(work: BackgroundWork) async throws -> CloudMoveFolder? {
        guard source != nil else { return nil }
        return try await work.run(.userBlocking, mayBlock: .files) { resolvedFolder() }
    }

    /// The git working copy around ``source``, read from disk now. Only a working copy is copied: a
    /// plain folder (`/Users`, `~/Downloads`, a disk) could hold anything, the home folder included,
    /// and neither the home folder (a dotfiles repository) nor the disk's root is ever copied.
    public func resolvedFolder() -> CloudMoveFolder? {
        guard let folder = source.flatMap(CloudMoveFolder.init(chat:)), !folder.isTooBroad,
              FileManager.checked.fileExists(atPath: (folder.root as NSString).appendingPathComponent(".git")) else { return nil }
        return folder
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
