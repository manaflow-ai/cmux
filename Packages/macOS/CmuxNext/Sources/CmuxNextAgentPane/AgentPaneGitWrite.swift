import Foundation

/// A change to the chat session's repository that the changes view asks
/// for: `git.commit` with `{message, all?, include_untracked?,
/// expected_head?, idempotency_key}` or `git.push` with `{expected_head?,
/// idempotency_key}`. The App runs it as the session host's mutation of the
/// same name in the folder of the pane's own session, which the host reads
/// from acpmux (``AgentPaneHostProviding/sessionFolder(sessionId:)``). A
/// `cwd` the page sends is ignored: a page cannot point a commit or push at
/// another repository. (The read-only git requests still take the page's
/// `cwd`.)
///
/// The page offers only what its buttons do: no paths, amend, no-verify,
/// remote or branch. The key is the page's, one per user action, so a
/// retry of the same action replays its first result instead of committing
/// or pushing twice.
public nonisolated enum AgentPaneGitWrite: Equatable, Sendable {
    /// With `all` false the index is committed as it is (the Staged
    /// toggle); with `all` every tracked change, and `includeUntracked` adds
    /// untracked, nonignored files.
    case commit(message: String, all: Bool, includeUntracked: Bool, expectedHead: String?, key: String)
    /// The current branch to where `git push` would send it; never forced.
    case push(expectedHead: String?, key: String)

    /// The session host's limit on a message, in UTF-8 bytes (64 KiB).
    public static let maximumMessageBytes = 65_536

    /// The session host's operation.
    public var operation: String {
        switch self {
        case .commit: "git.commit"
        case .push: "git.push"
        }
    }

    /// The page's idempotency key for this user action.
    public var key: String {
        switch self {
        case .commit(_, _, _, _, let key), .push(_, let key): key
        }
    }

    /// A key as the page mints them (a UUID): 1 to 128 visible ASCII characters.
    static func isKey(_ key: String) -> Bool {
        (1...128).contains(key.utf8.count) && key.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
    }

    /// A commit id as git status reports it: 4 to 64 hexadecimal digits.
    static func isCommit(_ id: String) -> Bool {
        (4...64).contains(id.utf8.count) && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Nil unless `params` name a valid key and, for a commit, a message of 1 byte to 64 KiB with a visible character. An
    /// `expected_head` must be a hexadecimal commit id; booleans default to
    /// false and anything else of the wrong type refuses.
    init?(method: String, params: [String: Any]?) {
        guard let params, let key = params["idempotency_key"] as? String, Self.isKey(key) else { return nil }
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
            self = .commit(message: message, all: all, includeUntracked: untracked, expectedHead: expectedHead, key: key)
        case "git.push":
            self = .push(expectedHead: expectedHead, key: key)
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
