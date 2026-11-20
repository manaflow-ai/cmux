public import Foundation

/// What a chat's Cloud machine is sized for: `POST /api/vm`'s `autosize.taskKind` (web/services/vms/autosize.ts).
/// Rust infers it from the chat's words (`moves::autosize::task_kind`).
public enum CloudTaskKind: String, Sendable, Equatable, CaseIterable, Codable {
    case chat, build, test

    /// The kind the chat's own words make obvious, else ``chat``; nil text is a chat.
    public static func inferred(from text: String?) -> CloudTaskKind {
        struct Request: Encodable { var text: String? }
        struct Reply: Decodable { var kind: CloudTaskKind }
        return CloudMoveCore().call("task_kind", Request(text: text), as: Reply.self)?.kind ?? .chat
    }
}

/// `POST /api/vm`'s `autosize`: the repo's identity, size and root files, and the task kind. Its JSON body is
/// Rust's (op `cloud_move_autosize_body`).
public struct CloudAutosizeRequest: Equatable, Sendable, Codable {
    public var taskKind: CloudTaskKind
    /// `host/owner/name`, lower-cased: the key the server files measured runs under.
    public var repoKey: String?
    /// The repository's git objects in MiB; nil outside git.
    public var repoSizeMb: Int?
    /// The names at the working copy's top, which tell the server the toolchain.
    public var rootFiles: [String]

    public init(taskKind: CloudTaskKind = .chat, repoKey: String? = nil, repoSizeMb: Int? = nil, rootFiles: [String] = []) {
        (self.taskKind, self.repoKey, self.repoSizeMb, self.rootFiles) = (taskKind, repoKey, repoSizeMb, rootFiles)
    }
}

/// The create answer's `sizePick` (`POST /api/vm` with `autosize`): the shape the server chose and one line on why.
/// Its fields are the hand-off's `size` (`POST /v1/handoffs {sessionId, machine, size}`), as ``handoffSize``.
public struct CloudSizePick: Equatable, Hashable, Sendable, Codable {
    public var vcpus: Int
    public var memoryGb: Double
    /// The ladder row's name (`sm`, `md`, `lg`, …).
    public var pick: String
    /// The one line the chat shows.
    public var reason: String

    public init(vcpus: Int, memoryGb: Double, pick: String, reason: String) {
        (self.vcpus, self.memoryGb, self.pick, self.reason) = (vcpus, memoryGb, pick, reason)
    }

    /// `POST /v1/handoffs`'s `size` object.
    public var handoffSize: [String: any Sendable] { ["vcpus": vcpus, "memoryGb": memoryGb, "pick": pick, "reason": reason] }
}
