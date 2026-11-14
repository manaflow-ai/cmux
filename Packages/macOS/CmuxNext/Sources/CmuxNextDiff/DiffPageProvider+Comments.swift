public import CmuxNextAgentPane
public import CmuxNextDaemonService
import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// Where a diff tab's review comments live: the session host's `diff.comments.*`, keyed by the
/// repository root, so they outlive the page and the app until they are sent (hq #7563).
public protocol DiffCommentsStoring: AnyObject {
    /// `diff.comments.list {root}`: the saved comments, oldest first.
    func listComments(root: String) async throws(AgentPaneGitFailure) -> JSONValue
    /// `diff.comments.save {root, comment}`: the stored record (the host owns id and dates).
    func saveComment(root: String, comment: JSONValue, key: String) async throws(AgentPaneGitFailure) -> JSONValue
    /// `diff.comments.delete {root, ids, versions}` → `{deleted, ids}`: a comment `versions` names
    /// goes only while its `updatedAt` is still that version, checked under the host's lock.
    func deleteComments(root: String, ids: [String], versions: [String: JSONValue], key: String) async throws(AgentPaneGitFailure) -> JSONValue
}

/// The diff tab's review comments (hq #7563): `cmux.diff.comments {method, params}` carries the
/// page's comment methods (webviews/src/comments/bridge.ts):
/// - `comments.list {repoRoot}` → `{comments}`, `comments.save {repoRoot, comment}` → `{comment}`,
///   `comments.delete {repoRoot, id}`: the session host's store, for the tab's own repository only;
/// - `comments.send {repoRoot, ids, versions, text}`: `text` (every comment as one prompt) to the
///   chat that opened the tab, then those comments leave the store unless edited since
///   (`versions`: each id's `updatedAt` as sent); answers `{sent, cleared}`. It needs a real click or key, and the
///   page's opid is the prompt's id, so a resend is delivered once.
/// Viewed files and prefs have their own ops (DiffPageProvider+Stores.swift); the page uses those.
extension DiffPageProvider {
    static let commentsOp = "cmux.diff.comments"
    /// The most comments one send names.
    static let maximumSentComments = 500

    /// The session host's comment store, when the tab's git has one.
    var commentStore: (any DiffCommentsStoring)? { git as? any DiffCommentsStoring }

    /// Answers `cmux.diff.comments`; nil for any other op.
    func commentsCall(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue? {
        guard op == Self.commentsOp else { return nil }
        guard let store = commentStore else { throw PageError.unknownOp(op) }
        let method = params["method"]?.stringValue ?? ""
        let inner = params["params"] ?? [:]
        let root = try await commentRoot(inner["repoRoot"])
        let key = context.opid ?? UUID().uuidString
        do {
            switch method {
            case "comments.list":
                return ["comments": .array(try await store.listComments(root: root)["comments"]?.arrayValue ?? [])]
            case "comments.save":
                guard let comment = inner["comment"], comment.objectValue != nil else { throw PageError.invalidParams("comment is required") }
                guard let saved = try await store.saveComment(root: root, comment: comment, key: key)["comment"] else {
                    throw PageError(code: "cmux.diff.comments_unavailable", message: "The comment was not saved")
                }
                return ["comment": saved]
            case "comments.delete":
                guard let id = inner["id"]?.stringValue else { throw PageError.invalidParams("id is required") }
                _ = try await store.deleteComments(root: root, ids: [id], versions: [:], key: key)
                return .object([:])
            case "comments.send":
                return try await sendComments(inner, root: root, store: store, context: context)
            default:
                throw PageError(code: "cmux.diff.unsupported", message: method)
            }
        } catch let failure as AgentPaneGitFailure {
            throw remote ? remoteError(failure) : Self.pageError(failure)
        }
    }

    private func sendComments(_ params: JSONValue, root: String, store: any DiffCommentsStoring,
                              context: PageCallContext) async throws -> JSONValue {
        guard context.userGesture else {
            throw PageError(code: "transport.gesture_required", message: "Sending needs a click or key in the page")
        }
        let ids = params["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard let text = params["text"]?.stringValue, !text.isEmpty, !ids.isEmpty, ids.count <= Self.maximumSentComments else {
            throw PageError.invalidParams("ids and text are required")
        }
        guard let chat = chat() else {
            throw PageError(code: "cmux.diff.no_chat", message: "No chat owns this diff")
        }
        let promptID = context.opid ?? UUID().uuidString
        guard await chat.send(text, promptID: promptID) else {
            throw PageError(code: "cmux.diff.send_failed", message: "The chat did not take the comments")
        }
        // The chat has them: they leave the store, except one edited since the page sent it (its
        // `updatedAt` moved on), which stays for the next send. The host checks each version and
        // deletes in one step under its lock. A failed delete leaves them listed, never lost.
        let versions = params["versions"]?.objectValue ?? [:]
        let deleted = try await store.deleteComments(root: root, ids: ids, versions: versions, key: promptID + "-clear")
        let cleared = deleted["ids"]?.arrayValue ?? []
        return ["sent": .number(Double(ids.count)), "cleared": .array(cleared)]
    }

    /// The tab's repository root: a page names only its own.
    private func commentRoot(_ named: JSONValue?) async throws -> String {
        let root = try await gitRepository()
        guard named?.stringValue == root else { throw PageError(code: "notAllowed", message: "Not this tab's repository") }
        return root
    }

    /// `config` listing `cmux.diff.comments` and, when the tab's chat can take them,
    /// `payload.commentsSend` (the page's Send to agent).
    func withComments(_ config: JSONValue) -> JSONValue {
        guard commentStore != nil, case .object(var members) = config, members["pick"] == nil else { return config }
        members["ops"] = .array((members["ops"]?.arrayValue ?? []) + [.string(Self.commentsOp)])
        if chat() != nil, case .object(var payload)? = members["payload"] {
            payload["commentsSend"] = true
            members["payload"] = .object(payload)
        }
        return .object(members)
    }
}

extension DiffAgentGit: DiffCommentsStoring {
    public func listComments(root: String) async throws(AgentPaneGitFailure) -> JSONValue {
        try Self.parseComments(try await link.read("diff.comments.list", params: ["root": .string(root)]))
    }

    public func saveComment(root: String, comment: JSONValue, key: String) async throws(AgentPaneGitFailure) -> JSONValue {
        try await mutate("diff.comments.save", ["root": .string(root), "comment": comment], key: key)
    }

    public func deleteComments(root: String, ids: [String], versions: [String: JSONValue], key: String) async throws(AgentPaneGitFailure) -> JSONValue {
        var params: [String: JSONValue] = ["root": .string(root), "ids": .array(ids.map(JSONValue.string))]
        if !versions.isEmpty { params["versions"] = .object(versions) }
        return try await mutate("diff.comments.delete", .object(params), key: key)
    }

    private func mutate(_ operation: String, _ params: JSONValue, key: String) async throws(AgentPaneGitFailure) -> JSONValue {
        try Self.mutationValue(try await link.mutate(operation, params: Data(params.compactText.utf8), idempotencyKey: key))
    }

    private static func parseComments(_ data: Data) throws(AgentPaneGitFailure) -> JSONValue {
        guard let value = try? JSONValue.parse(data) else { throw AgentPaneGitFailure.failed }
        return value
    }

    /// A mutation's `MutationResult` `{value, generation, revision, replayed}`: its `value`.
    private static func mutationValue(_ data: Data) throws(AgentPaneGitFailure) -> JSONValue {
        guard let value = try parseComments(data)["value"] else { throw AgentPaneGitFailure.failed }
        return value
    }
}
