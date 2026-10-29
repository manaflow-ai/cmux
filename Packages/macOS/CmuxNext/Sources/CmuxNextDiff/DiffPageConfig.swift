public import CmuxNextSettings
public import Foundation

/// The repository a diff tab shows, from the session host's `git.status` of
/// the tab's folder: its root, the checked-out branch, and the daemon's base
/// branch (origin's default branch, else origin/main, origin/master, main,
/// master; nil when it has none).
public nonisolated struct DiffRepository: Sendable, Equatable {
    public let root: String
    public let branch: String?
    public let base: String?

    /// From a `git.status` result; nil without a root.
    public init?(status: JSONValue) {
        guard let root = status["root"]?.stringValue, !root.isEmpty else { return nil }
        self.root = root
        branch = status["branch"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        base = status["base"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    public init(root: String, branch: String?, base: String?) {
        self.root = root
        self.branch = branch
        self.base = base
    }

    public var name: String { URL(fileURLWithPath: root).lastPathComponent }
}

/// What a diff tab compares first (the page can switch afterwards).
public nonisolated enum DiffOpenSource: Sendable, Hashable {
    /// The branch against `base`; nil is the daemon's base branch.
    case branch(base: String?)
    case unstaged
    case staged
    /// The tab's chat turn (``DiffTurn``, the Last turn scope), read-only.
    case turn

    /// The branch against the daemon's base.
    public static let `default` = DiffOpenSource.branch(base: nil)
}

/// A chat turn a diff tab offers as its Last turn scope (D2): checkpoint `from` against `to`, the
/// pair acpmux records before a prompt and when the turn ends. The session host diffs the pair
/// (`git.checkpoint.diff`); the tab shows it read-only. `file`: the repository-relative path the tab
/// scrolls to and unfolds when it opens on the turn (an edited-files row).
public nonisolated struct DiffTurn: Sendable, Hashable {
    public let from: String
    public let to: String
    public let file: String?

    public init(from: String, to: String, file: String? = nil) {
        self.from = from
        self.to = to
        self.file = file
    }

    /// Nil unless `from` and `to` are checkpoint ids as the session host mints them (1 to 128
    /// visible ASCII characters); a `file` that is not a relative path inside the repository is
    /// dropped.
    public init?(checking from: String?, to: String?, file: String?) {
        guard let from, let to, Self.isCheckpoint(from), Self.isCheckpoint(to) else { return nil }
        let inside = file.map { path in
            !path.isEmpty && path.utf8.count <= 4096 && !path.hasPrefix("/") && !path.contains("\u{0}")
                && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != ".." && $0 != "." && !$0.isEmpty }
        }
        self.init(from: from, to: to, file: inside == true ? file : nil)
    }

    static func isCheckpoint(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
    }
}

/// What `cmux.diff.config` answers (webviews/src/diff/page.ts): the viewer
/// config the classic CLI embedded as `<script id="cmux-diff-viewer-config">`,
/// plus `ops`, the optional ops this host serves. Comments, viewed files and
/// prefs arrive with S5, so `ops` lists none and the page keeps comments hidden.
nonisolated enum DiffPageConfig {
    /// The optional ops served (`cmux.diff.comments` is S5).
    static let ops: [String] = []
    /// The sidecar session options the page may use, by their handshake capability names
    /// (Native/DiffSidecar/src/protocol.rs). The bundled sidecar is built with the app, so its
    /// handshake answers these. `session.ignoreWhitespace`: the "..." menu's Hide white space,
    /// for the git sources only (a patch source cannot hide it). `session.fileContents`: a
    /// file's two sides (`fileContents`) for Load full files, also for the git sources only.
    static let sessionCapabilities: [String] = ["session.ignoreWhitespace", "session.fileContents"]

    /// `source` with the daemon's base for a branch with none named; a
    /// repository with no base at all starts on the unstaged changes. With a
    /// `turn`, the scope menu offers Last turn (the patch at
    /// ``DiffTurnPatch/requestPath``); `.turn` opens on it, at the turn's file.
    static func make(repository: DiffRepository, source: DiffOpenSource = .default, token: String,
                     turn: DiffTurn? = nil) -> JSONValue {
        var payload: [String: JSONValue] = [
            "title": .string(repository.name),
            "transport": ["kind": "page", "endpoint": "cmux.diff", "protocolVersion": 1],
            "capabilityToken": .string(token),
            "repoRoot": .string(repository.root),
            "headRef": .string(repository.branch ?? "HEAD"),
            "layout": "auto",
            "layoutSource": "default",
            "sessionCapabilities": .array(sessionCapabilities.map(JSONValue.string)),
        ]
        let root = JSONValue.string(repository.root)
        // A turn scope with no turn (a restored tab) shows the default scope.
        switch turn == nil && source == .turn ? DiffOpenSource.default : source {
        case .branch(let named):
            if let base = named ?? repository.base {
                payload["sessionSource"] = ["kind": "branch", "repoRoot": root, "baseRef": .string(base)]
                payload["branchBaseRef"] = .string(base)
            } else {
                payload["sessionSource"] = ["kind": "unstaged", "repoRoot": root]
            }
        case .unstaged:
            payload["sessionSource"] = ["kind": "unstaged", "repoRoot": root]
        case .staged:
            payload["sessionSource"] = ["kind": "staged", "repoRoot": root]
        case .turn:
            payload["sessionSource"] = DiffTurnPatch.pageSource
            if let base = repository.base { payload["branchBaseRef"] = .string(base) }
            if let file = turn?.file { payload["revealPath"] = .string(file) }
        }
        if turn != nil {
            payload["sourceOptions"] = [["value": "last-turn", "sessionSource": DiffTurnPatch.pageSource]]
        }
        return ["payload": .object(payload), "ops": .array(ops.map(JSONValue.string))]
    }

    /// `config` with Last turn in its scope menu.
    static func offeringTurn(_ config: JSONValue) -> JSONValue {
        guard case .object(var members) = config, case .object(var payload)? = members["payload"] else { return config }
        payload["sourceOptions"] = [["value": "last-turn", "sessionSource": DiffTurnPatch.pageSource]]
        members["payload"] = .object(payload)
        return .object(members)
    }

    /// A page that shows only `message` as an error (the folder is not a
    /// repository, the sidecar is missing).
    static func failure(title: String, message: String) -> JSONValue {
        ["payload": ["title": .string(title), "statusMessage": .string(message), "statusIsError": true],
         "ops": .array([])]
    }
}
