import Foundation

/// A diff review thread of a worktree on the linked Mac, as the session host lists it
/// (`diff.comments.list`; cmux-tui-core `git_ops/diff_comments.rs`, `thread.rs`, `chase.rs`):
/// the page's comment (`filePath`, `endLine`, `message`), its replies, whether it is resolved,
/// and the chase marks of a thread the agent took and has not answered.
public struct DiffReviewThread: Identifiable, Hashable, Sendable {
    public struct Reply: Identifiable, Hashable, Sendable {
        public var id: String
        /// `reviewer` (the person) or `agent`.
        public var author: String
        public var text: String
        public var createdAt: String?

        public var isAgent: Bool { author == "agent" }
    }

    /// Where the thread stands, the order the list shows them in.
    public enum State: Hashable, Sendable {
        /// The agent gave up three chases without an answer (`stalled`).
        case stalled
        /// Sent to an agent that has not answered yet; `chases` times it was sent again.
        case awaitingAgent(chases: Int)
        /// Not resolved, and nothing waits on the agent.
        case open
        case resolved
    }

    public var id: String
    public var filePath: String
    public var line: Int?
    public var message: String
    /// The `updatedAt` the Mac gave it, which a send carries back as its version.
    public var updatedAt: String
    public var replies: [Reply]
    public var resolved: Bool
    /// The acpmux chat it was last sent to (`sentTo`).
    public var sentTo: String?
    public var chases: Int
    public var stalled: Bool
    /// How many agent replies it had when it was sent (`agentRepliesAtSend`).
    public var agentRepliesAtSend: Int?

    public init(id: String, filePath: String, line: Int?, message: String, updatedAt: String, replies: [Reply] = [],
                resolved: Bool = false, sentTo: String? = nil, chases: Int = 0, stalled: Bool = false,
                agentRepliesAtSend: Int? = nil) {
        self.id = id
        self.filePath = filePath
        self.line = line
        self.message = message
        self.updatedAt = updatedAt
        self.replies = replies
        self.resolved = resolved
        self.sentTo = sentTo
        self.chases = chases
        self.stalled = stalled
        self.agentRepliesAtSend = agentRepliesAtSend
    }

    public var state: State {
        if resolved { return .resolved }
        if stalled { return .stalled }
        if sentTo != nil, let atSend = agentRepliesAtSend, replies.count(where: \.isAgent) <= atSend {
            return .awaitingAgent(chases: chases)
        }
        return .open
    }

    /// `file.swift:12`, or the path alone.
    public var location: String { line.map { "\(filePath):\($0)" } ?? filePath }

    /// One comment object of the list; nil without an id.
    public init?(json object: [String: Any]) {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        let replies = (object["replies"] as? [[String: Any]] ?? []).compactMap { reply -> Reply? in
            guard let text = reply["text"] as? String else { return nil }
            return Reply(id: reply["id"] as? String ?? UUID().uuidString, author: reply["author"] as? String ?? "reviewer",
                         text: text, createdAt: reply["createdAt"] as? String)
        }
        self.init(
            id: id,
            filePath: object["filePath"] as? String ?? "",
            line: Self.int(object["endLine"]) ?? Self.int(object["startLine"]),
            message: object["message"] as? String ?? "",
            updatedAt: object["updatedAt"] as? String ?? "",
            replies: replies,
            resolved: object["resolved"] as? Bool ?? false,
            sentTo: (object["sentTo"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            chases: Self.int(object["chases"]) ?? 0,
            stalled: object["stalled"] as? Bool ?? false,
            agentRepliesAtSend: Self.int(object["agentRepliesAtSend"])
        )
    }

    /// The threads of a `diff.comments.list` reply (the whole line or its `result`), stalled
    /// first, then those waiting on the agent, the open ones and the resolved ones, each in the
    /// Mac's order.
    public static func threads(fromList reply: [String: Any]) -> [DiffReviewThread] {
        let result = reply["result"] as? [String: Any] ?? reply
        let comments = (result["comments"] as? [[String: Any]] ?? []).compactMap(DiffReviewThread.init(json:))
        return comments.enumerated().sorted { a, b in
            let (ra, rb) = (a.element.state.rank, b.element.state.rank)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: value
        case let value as Double: Int(value)
        case let value as NSNumber: value.intValue
        default: nil
        }
    }
}

extension DiffReviewThread.State {
    var rank: Int {
        switch self {
        case .stalled: 0
        case .awaitingAgent: 1
        case .open: 2
        case .resolved: 3
        }
    }
}

/// The diff review threads a phone reads and answers on a Mac (cmux#65783, hostd's
/// `Ownership::TabFolder`): only the worktree of a tab open there, only as the reviewer, and a
/// send hands back the threads alone (the Mac writes the prompt).
@MainActor
public protocol DiffReviewThreadsBackend: AnyObject {
    /// Whether `macID`'s daemon lane is up, so the operations can reach it.
    func canReviewThreads(on macID: String) -> Bool
    /// `diff.comments.list {root}`.
    func reviewThreads(root: String, on macID: String) async throws -> [DiffReviewThread]
    /// `diff.comments.thread {root, id, reply, author: reviewer}`.
    func reply(_ text: String, to thread: String, root: String, on macID: String) async throws
    /// `diff.comments.thread {root, id, resolved}`.
    func setResolved(_ resolved: Bool, thread: String, root: String, on macID: String) async throws
    /// `diff.comments.send {root, acp_session, ids, versions, threads: true}`.
    func sendBack(_ threads: [DiffReviewThread], root: String, chat: String, on macID: String) async throws
}

/// Where the chat screens find the review threads backend, set once the shell links Macs.
@MainActor
public final class DiffReviewThreadsCenter {
    public static let shared = DiffReviewThreadsCenter()

    /// Weak: the shell owns it (`MultiMacWorkspaceBackend`).
    public weak var backend: (any DiffReviewThreadsBackend)?
    public var flag: DiffReviewThreadsFlag

    public init(flag: DiffReviewThreadsFlag = DiffReviewThreadsFlag()) {
        self.flag = flag
    }

    /// The flag is on and `macID` can take the operations now.
    public func isAvailable(on macID: String) -> Bool {
        guard flag.isEnabled, !macID.isEmpty, let backend else { return false }
        return backend.canReviewThreads(on: macID)
    }
}

/// Review Threads on the phone, off until it has been tried on a real phone: env
/// `CMUX_DIFF_REVIEW_THREADS=1` or defaults key `cmux.debug.diffReviewThreads` turns it on. It
/// also needs the daemon lane (`cmux.debug.daemonLane`), which carries the operations.
public struct DiffReviewThreadsFlag: Sendable {
    public static let defaultsKey = "cmux.debug.diffReviewThreads"
    public static let environmentKey = "CMUX_DIFF_REVIEW_THREADS"

    private let environmentValue: String?
    private let defaultsValue: Bool?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) {
        environmentValue = environment[Self.environmentKey]
        defaultsValue = defaults.object(forKey: Self.defaultsKey) == nil ? nil : defaults.bool(forKey: Self.defaultsKey)
    }

    public var isEnabled: Bool {
        if let raw = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return ["1", "true", "yes", "on"].contains(raw.lowercased())
        }
        return defaultsValue ?? false
    }
}
