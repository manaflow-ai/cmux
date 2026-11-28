import CmuxNextSettings
import Foundation

/// The repository a diff tab shows, from the session host's `git.status` of
/// the tab's folder: its root, the checked-out branch, and the daemon's base
/// branch (origin's default branch, else origin/main, origin/master, main,
/// master; nil when it has none).
nonisolated struct DiffRepository: Sendable, Equatable {
    let root: String
    let branch: String?
    let base: String?

    /// From a `git.status` result; nil without a root.
    init?(status: JSONValue) {
        guard let root = status["root"]?.stringValue, !root.isEmpty else { return nil }
        self.root = root
        branch = status["branch"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        base = status["base"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    init(root: String, branch: String?, base: String?) {
        self.root = root
        self.branch = branch
        self.base = base
    }

    var name: String { URL(fileURLWithPath: root).lastPathComponent }
}

/// What a diff tab compares first (the page can switch afterwards).
nonisolated enum DiffOpenSource: Sendable, Hashable {
    /// The branch against `base`; nil is the daemon's base branch.
    case branch(base: String?)
    case unstaged
    case staged

    /// The branch against the daemon's base.
    static let `default` = DiffOpenSource.branch(base: nil)
}

/// What `cmux.diff.config` answers (webviews/src/diff/page.ts): the viewer
/// config the classic CLI embedded as `<script id="cmux-diff-viewer-config">`,
/// plus `ops`, the optional ops this host serves. Comments, viewed files and
/// prefs arrive with S5, so `ops` lists none and the page keeps comments hidden.
nonisolated enum DiffPageConfig {
    /// The optional ops served (`cmux.diff.comments` is S5).
    static let ops: [String] = []

    /// `source` with the daemon's base for a branch with none named; a
    /// repository with no base at all starts on the unstaged changes.
    static func make(repository: DiffRepository, source: DiffOpenSource = .default, token: String) -> JSONValue {
        var payload: [String: JSONValue] = [
            "title": .string(repository.name),
            "transport": ["kind": "page", "endpoint": "cmux.diff", "protocolVersion": 1],
            "capabilityToken": .string(token),
            "repoRoot": .string(repository.root),
            "headRef": .string(repository.branch ?? "HEAD"),
            "layout": "split",
            "layoutSource": "default",
        ]
        let root = JSONValue.string(repository.root)
        switch source {
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
        }
        return ["payload": .object(payload), "ops": .array(ops.map(JSONValue.string))]
    }

    /// A page that shows only `message` as an error (the folder is not a
    /// repository, the sidecar is missing).
    static func failure(title: String, message: String) -> JSONValue {
        ["payload": ["title": .string(title), "statusMessage": .string(message), "statusIsError": true],
         "ops": .array([])]
    }
}
