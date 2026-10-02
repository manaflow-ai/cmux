import Foundation

/// A repository checkpoint operation the page's checkpoint review asks for
/// (cx-checkpoint-capture-contract v1.1). The App sends it to the session
/// host as the resource operation of the same name, with `cwd` as `path`.
///
/// `create`, `pin` and `unpin` are mutations: their `idempotency_key` goes in
/// the request envelope, and the page keeps it across an uncertain reply.
/// `get` and `list` are reads with no envelope key; `get` may name the key a
/// create used as a lookup field instead.
public nonisolated enum AgentPaneCheckpointRequest: Equatable, Sendable {
    /// Which record `git.checkpoint.get` returns: exactly one of the two.
    public nonisolated enum Lookup: Equatable, Sendable {
        case checkpointID(String)
        /// The key a create used, which recovers an uncertain create reply.
        case idempotencyKey(String)
    }

    /// `git.checkpoint.create`: captures the folder's repository.
    case create(cwd: String, options: AgentPaneCheckpointCreate, idempotencyKey: String)
    /// `git.checkpoint.get`: one record.
    case get(cwd: String, lookup: Lookup)
    /// `git.checkpoint.list`: the repository's records, and with
    /// `includeCandidates` the untracked files a create may store.
    case list(cwd: String, cursor: String?, limit: Int?, includeCandidates: Bool?)
    /// `git.checkpoint.pin`: keeps a record from pruning under `pinID`.
    case pin(cwd: String, checkpointID: String, pinID: String, reason: String, idempotencyKey: String)
    /// `git.checkpoint.unpin`: removes one of the record's user pins.
    case unpin(cwd: String, checkpointID: String, pinID: String, idempotencyKey: String)

    /// The page methods, which are also the session host's operations.
    public static let methods: Set<String> = [
        "git.checkpoint.create", "git.checkpoint.get", "git.checkpoint.list", "git.checkpoint.pin", "git.checkpoint.unpin",
    ]

    /// The session host's operation.
    public var operation: String {
        switch self {
        case .create: "git.checkpoint.create"
        case .get: "git.checkpoint.get"
        case .list: "git.checkpoint.list"
        case .pin: "git.checkpoint.pin"
        case .unpin: "git.checkpoint.unpin"
        }
    }

    /// The session's folder, absolute.
    public var cwd: String {
        switch self {
        case .create(let cwd, _, _), .get(let cwd, _), .list(let cwd, _, _, _),
             .pin(let cwd, _, _, _, _), .unpin(let cwd, _, _, _):
            cwd
        }
    }

    /// The request envelope's `idempotency_key`: set on the three mutations,
    /// nil on the reads (a `get` lookup key is a param, not this).
    public var idempotencyKey: String? {
        switch self {
        case .create(_, _, let key), .pin(_, _, _, _, let key), .unpin(_, _, _, let key): key
        case .get, .list: nil
        }
    }
}
