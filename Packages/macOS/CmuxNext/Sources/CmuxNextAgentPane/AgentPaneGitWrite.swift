import Foundation

/// A change to the chat session's repository that the changes view asks
/// for: `git.commit` with `{session_id, message, all?, include_untracked?,
/// expected_head?, idempotency_key}` or `git.push` with `{session_id,
/// expected_head?, idempotency_key}`. `session_id` is the chat session the
/// page read `git.status` for; the model refuses the write unless it is the
/// pane's own session, so a view read for one chat never writes another's
/// repository. The App runs it as the session host's mutation of the
/// same name in the folder of the pane's own session, which the host reads
/// from acpmux (``AgentPaneHostProviding/sessionFolder(sessionId:)``). A
/// `cwd` the page sends is ignored: a page cannot point a commit or push at
/// another repository. (The read-only git requests still take the page's
/// `cwd`.)
///
/// `git.worktree.create` with `{cwd, name?, idempotency_key}` (cx-lyqio.2) is
/// a new chat's New Worktree: it has no session yet, so it runs in the `cwd`
/// the page names, which the model takes only when a chat may start there
/// (the check a picked folder gets).
///
/// `git.worktree.apply` with `{session_id, idempotency_key}` (cx-lyqio.4) is
/// a worktree chat's Apply: like a push it runs in the folder of the pane's
/// own session, and brings that worktree's work to its main checkout.
/// `git.worktree.remove` with `{session_id, discard?, idempotency_key}`
/// (cx-lyqio.5) is its Remove, in the same folder: the worktree and the
/// branch New Worktree made go, and `discard` (the page's "Remove anyway")
/// lets work found nowhere else go with them.
///
/// The page offers only what its buttons do: no paths, amend, no-verify,
/// remote or branch. The key is the page's, one per user action, so a
/// retry of the same action replays its first result instead of committing
/// or pushing twice.
public nonisolated enum AgentPaneGitWrite: Equatable, Sendable {
    /// With `all` false the index is committed as it is (the Staged
    /// toggle); with `all` every tracked change, and `includeUntracked` adds
    /// untracked, nonignored files.
    case commit(sessionId: String, message: String, all: Bool, includeUntracked: Bool, expectedHead: String?, key: String)
    /// The current branch to where `git push` would send it; never forced.
    case push(sessionId: String, expectedHead: String?, key: String)
    /// A new chat's own worktree of `cwd`, the chat's folder (cx-lyqio.2).
    case worktree(cwd: String, name: String?, key: String)
    /// The chat's worktree work, onto its main checkout (cx-lyqio.4).
    case worktreeApply(sessionId: String, key: String)
    /// The chat's worktree removed; `discard` removes work found nowhere
    /// else too (cx-lyqio.5).
    case worktreeRemove(sessionId: String, discard: Bool, key: String)

    /// The page methods that carry a write.
    public static let methods: Set<String> = ["git.commit", "git.push", "git.worktree.create", "git.worktree.apply", "git.worktree.remove"]

    /// The session host's limit on a worktree name.
    static let maximumNameCharacters = 100

    /// The session host's limit on a message, in UTF-8 bytes (64 KiB).
    public static let maximumMessageBytes = 65_536

    /// The session host's operation.
    public var operation: String {
        switch self {
        case .commit: "git.commit"
        case .push: "git.push"
        case .worktree: "git.worktree.create"
        case .worktreeApply: "git.worktree.apply"
        case .worktreeRemove: "git.worktree.remove"
        }
    }

    /// The page's idempotency key for this user action.
    public var key: String {
        switch self {
        case .commit(_, _, _, _, _, let key), .push(_, _, let key), .worktree(_, _, let key), .worktreeApply(_, let key),
             .worktreeRemove(_, _, let key): key
        }
    }

    /// The session the page read the repository's status for; none for a
    /// new chat's worktree.
    public var sessionId: String? {
        switch self {
        case .commit(let sessionId, _, _, _, _, _), .push(let sessionId, _, _), .worktreeApply(let sessionId, _),
             .worktreeRemove(let sessionId, _, _): sessionId
        case .worktree: nil
        }
    }

    /// A key as the page mints them (a UUID): 1 to 128 visible ASCII characters.
    static func isKey(_ key: String) -> Bool {
        (1...128).contains(key.utf8.count) && key.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
    }

    /// A full commit id as git status reports it: 40 (SHA-1) or 64 (SHA-256)
    /// hexadecimal digits. The host compares it exactly, so a short id
    /// could only ever answer `head_moved`.
    static func isCommit(_ id: String) -> Bool {
        [40, 64].contains(id.utf8.count) && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Nil unless `params` name a valid key and, for a commit, a message of 1 byte to 64 KiB with a visible character. An
    /// `expected_head` must be a hexadecimal commit id; booleans default to
    /// false and anything else of the wrong type refuses.
    public init?(method: String, params: [String: Any]?) {
        guard let params, let key = params["idempotency_key"] as? String, Self.isKey(key) else { return nil }
        if method == "git.worktree.create" {
            guard let cwd = params["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0") else { return nil }
            switch params["name"] {
            case nil, is NSNull: self = .worktree(cwd: cwd, name: nil, key: key)
            case let name as String where (1...Self.maximumNameCharacters).contains(name.count):
                self = .worktree(cwd: cwd, name: name, key: key)
            default: return nil
            }
            return
        }
        guard let sessionId = params["session_id"] as? String, Self.isKey(sessionId) else { return nil }
        let expectedHead: String?
        switch params["expected_head"] {
        case nil, is NSNull: expectedHead = nil
        case let head as String where Self.isCommit(head): expectedHead = head
        default: return nil
        }
        switch method {
        case "git.commit":
            guard let message = params["message"] as? String,
                  (1...Self.maximumMessageBytes).contains(message.utf8.count),
                  message.contains(where: { !$0.isWhitespace }),
                  let all = Self.flag(params["all"]), let untracked = Self.flag(params["include_untracked"]),
                  all || !untracked else { return nil }
            self = .commit(sessionId: sessionId, message: message, all: all, includeUntracked: untracked, expectedHead: expectedHead, key: key)
        case "git.push":
            self = .push(sessionId: sessionId, expectedHead: expectedHead, key: key)
        case "git.worktree.apply":
            self = .worktreeApply(sessionId: sessionId, key: key)
        case "git.worktree.remove":
            guard let discard = Self.flag(params["discard"]) else { return nil }
            self = .worktreeRemove(sessionId: sessionId, discard: discard, key: key)
        default:
            return nil
        }
    }

    /// False when absent, the value when a JSON boolean, else nil.
    private static func flag(_ value: Any?) -> Bool? {
        switch value {
        case nil, is NSNull: false
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): number.boolValue
        default: nil
        }
    }
}
