import CmuxNextCompat
public import CmuxNextWakeups
import CryptoKit
public import Foundation

/// The folder a chat moves with: the git working copy that holds the chat's folder, or the chat's
/// folder itself outside git. Rust finds it, names it on a machine and places it there
/// (`moves::folder`, ops `cloud_move_folder*`).
public nonisolated struct CloudMoveFolder: Sendable, Equatable, Decodable {
    /// The folder that is synced, absolute, on this Mac.
    public let root: String
    /// The chat's folder inside ``root``; empty for ``root`` itself.
    public let subpath: String
    /// ``root`` is a git working copy's top.
    public let git: Bool
    /// The folder's name on a machine: its own name and a short hash of where it is on this Mac.
    public let remoteName: String

    /// Whether `path` is an existing folder, read off the main thread before a copy starts.
    @concurrent nonisolated public static func isFolder(_ path: String) async -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.checked.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// Nil for a relative folder, or one whose `..` parts climb above the disk's root. Reads the disk for `.git`.
    ///
    /// - Parameter folder: The chat's folder, absolute, on this Mac.
    public init?(chat folder: String) {
        struct Request: Encodable { var chat: String }
        struct Reply: Decodable { var folder: CloudMoveFolder? }
        guard let found = CloudMoveCore().call("folder", Request(chat: folder), as: Reply.self)?.folder else { return nil }
        self = found
    }

    /// ``init(chat:)`` read off the main thread (it looks for `.git` above the folder).
    @concurrent nonisolated public static func read(chat folder: String) async -> CloudMoveFolder? {
        CloudMoveFolder(chat: folder)
    }

    /// `path` with its `.` and `..` parts resolved and no trailing slash, as written otherwise (standardizing
    /// would also turn /private/tmp into /tmp): nil for a relative path or one whose `..` parts climb above
    /// the disk's root. The same rule as Rust's `moves::folder::normalized`, which ``init(chat:)`` applies;
    /// `cmux cloud start-session --from-folder` checks its words with it before any machine is touched.
    public static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if parts.popLast() == nil { return nil }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// A start's copy key (`cmux link start-chat copy` takes a UUID's spelling) made of `machine` and `folder` (canonical):
    /// the same start again on the same machine is the same copy, which its ledger reuses (`cmux cloud start-session
    /// --from-folder`).
    public static func copyKey(machine: String, folder: String) -> String {
        let digest = SHA256.hash(data: Data("cmux cloud start-session --from-folder\u{0}\(machine)\u{0}\(folder)".utf8))
        var key = ""
        for (offset, character) in digest.prefix(16).map({ String(format: "%02x", $0) }).joined().enumerated() {
            if [8, 12, 16, 20].contains(offset) { key.append("-") }
            key.append(character)
        }
        return key
    }

    /// The home folder or the disk's root: never copied to a machine (Rust's `start::too_broad`, with both
    /// paths as Foundation standardizes them).
    public var isTooBroad: Bool {
        CloudStartCore().isTooBroad(root: URL(fileURLWithPath: root).standardizedFileURL.path,
                                    home: URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
    }

    /// The synced folder under `workRoot` on the machine, and the chat's folder there.
    public func remote(under workRoot: String) -> (folder: String, chat: String) {
        struct Request: Encodable { var root: String, subpath: String, workRoot: String }
        struct Reply: Decodable { var folder: String, chat: String }
        let reply = CloudMoveCore().call("folder_remote", Request(root: root, subpath: subpath, workRoot: workRoot), as: Reply.self)
        return (reply?.folder ?? workRoot, reply?.chat ?? workRoot)
    }
}

/// Where the Cloud toggle (`cloud.newWorkspacesInCloud`) sends a person's New Workspace: nil keeps it on this Mac;
/// otherwise a new Cloud machine of its own, starting in the person's folder copied there, or in its empty folder.
/// Rust decides (`moves::folder::plan`, `route`, `copy_step`); deciding reads no disk, the folder is resolved later.
public nonisolated struct CloudNewWorkspacePlan: Sendable, Equatable {
    /// The person's folder when Current Folder applies; nil starts in the machine's own empty folder.
    public let source: String?

    /// What one copy of a folder answered (`cmux link sync push`'s JSON line).
    public struct CopyAnswer: Sendable, Equatable, Encodable {
        public var ok: Bool, errorCode: String?, error: String?
        public init(ok: Bool, errorCode: String? = nil, error: String? = nil) {
            (self.ok, self.errorCode, self.error) = (ok, errorCode, error)
        }
    }

    /// Why a folder was not copied.
    public enum CopyFailure: Error, Equatable {
        /// The machine's cmux-tui is older than the copy needs (`machine_outdated`).
        case outdated
        /// Any other refusal, as the copy said it.
        case failed(String)
    }

    /// Where a planned New Workspace goes: to Cloud only where Cloud can make the machine and a window shows it.
    public enum Route: Sendable, Equatable {
        case cloud
        case thisMac(Refusal)
    }

    /// Why a New Workspace the toggle would send to Cloud opened on this Mac instead.
    public enum Refusal: Sendable, Equatable {
        case unavailable(String)
        case signedOut
        case noWindow
    }

    /// What New Workspace does after asking the toggle.
    public enum Outcome: Sendable, Equatable {
        /// A new machine's creation started, showing in the window: New Workspace makes nothing here.
        case started
        /// New Workspace opens on this Mac; `notice`, when the toggle is on, says why it is not in Cloud.
        case thisMac(notice: String?)
    }

    public static func route(unavailableReason: String?, signedIn: Bool, hasWindow: Bool) -> Route {
        struct Request: Encodable { var unavailableReason: String?, signedIn: Bool, hasWindow: Bool }
        struct Reply: Decodable {
            struct Why: Decodable { var kind: String, reason: String? }
            var route: String, refusal: Why?
        }
        let reply = CloudMoveCore().call("new_workspace_route", Request(unavailableReason: unavailableReason, signedIn: signedIn, hasWindow: hasWindow),
                                         as: Reply.self)
        guard let reply, reply.route != "cloud" else { return reply == nil ? .thisMac(.unavailable(unavailableReason ?? "")) : .cloud }
        switch reply.refusal?.kind {
        case "signedOut": return .thisMac(.signedOut)
        case "noWindow": return .thisMac(.noWindow)
        default: return .thisMac(.unavailable(reply.refusal?.reason ?? unavailableReason ?? ""))
        }
    }

    /// Nil keeps the New Workspace on this Mac: the toggle off (`inCloud`), not a person's gesture (`byPerson`), or a
    /// run naming a machine or command. `inheritsFolder`: `cloud.newWorkspaceFolder` is `inherit` and the app can copy.
    public init?(inCloud: Bool, inheritsFolder: Bool, cwd: String?, byPerson: Bool, namesMachineOrCommand: Bool) {
        struct Request: Encodable { var inCloud: Bool, inheritsFolder: Bool, cwd: String?, byPerson: Bool, namesMachineOrCommand: Bool }
        struct Reply: Decodable { var cloud: Bool, source: String? }
        let request = Request(inCloud: inCloud, inheritsFolder: inheritsFolder, cwd: cwd, byPerson: byPerson, namesMachineOrCommand: namesMachineOrCommand)
        guard let reply = CloudMoveCore().call("new_workspace_plan", request, as: Reply.self), reply.cloud else { return nil }
        source = reply.source
    }

    /// The folder copied to the machine, read on `work`'s files lane (never the main thread). Throws when the
    /// creation was cancelled meanwhile, so nothing more is made on the machine.
    public func folder(work: BackgroundWork) async throws -> CloudMoveFolder? {
        guard source != nil else { return nil }
        return try await work.run(.userBlocking, mayBlock: .files) { resolvedFolder() }
    }

    /// The git working copy around ``source``, read from disk now: only a working copy is copied, never the home
    /// folder or the disk's root.
    public func resolvedFolder() -> CloudMoveFolder? {
        guard let folder = source.flatMap(CloudMoveFolder.init(chat:)), folder.git, !folder.isTooBroad else { return nil }
        return folder
    }

    /// Copies `folder` under the first of `workRoots` the machine lets it write through `push(remote)`, as Rust's
    /// `copy_step` says after each push. Returns the copied folder and the person's folder in it, on the machine.
    public static func copy(_ folder: CloudMoveFolder, workRoots: [String],
                            push: (String) async throws -> CopyAnswer) async throws -> (folder: String, chat: String) {
        struct Request: Encodable { var ok: Bool, errorCode: String?, error: String?, last: Bool }
        struct Step: Decodable { var step: String, message: String? }
        var answer = CopyAnswer(ok: false)
        for (index, root) in workRoots.enumerated() {
            let remote = folder.remote(under: root)
            answer = try await push(remote.folder)
            let step = CloudMoveCore().call("copy_step", Request(ok: answer.ok, errorCode: answer.errorCode, error: answer.error,
                                                                  last: index == workRoots.count - 1), as: Step.self)
            switch step?.step {
            case "done": return remote
            case "next": continue
            case "outdated": throw CopyFailure.outdated
            default: throw CopyFailure.failed(step?.message ?? answer.error ?? answer.errorCode ?? "")
            }
        }
        throw CopyFailure.failed("")
    }
}

/// Which machine New Cloud Workspace (`cmux cloud new-workspace`) opens on: one workspace, one new small machine,
/// never one picked from the machines already listed (Rust's `new_workspace_machine`).
public nonisolated enum CloudNewWorkspaceMachine: Sendable, Equatable {
    case named(String)
    case focused(String)
    case new

    /// `named`: the machine a `--target machine:<id>` names; `byPerson`: the person's own gesture in this app;
    /// `focused`: the Cloud machine the active window shows, if any.
    public static func pick(named: String?, byPerson: Bool, focused: String?) -> Self {
        struct Request: Encodable { var named: String?, byPerson: Bool, focused: String? }
        struct Reply: Decodable { var kind: String, id: String? }
        let reply = CloudMoveCore().call("new_workspace_machine", Request(named: named, byPerson: byPerson, focused: focused), as: Reply.self)
        switch (reply?.kind, reply?.id) {
        case ("named", let id?): return .named(id)
        case ("focused", let id?): return .focused(id)
        default: return .new
        }
    }
}
