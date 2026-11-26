public import CmuxNextAgentPane
public import CmuxNextDaemonService
import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// Where a diff tab's review comments live: the session host's `diff.comments.*`, keyed by the
/// repository root, so they outlive the page and the app until they are sent (hq #7563).
public protocol DiffCommentsStoring: AnyObject {
    /// Whether the session host supports replies, resolution and threaded sends.
    var supportsCommentThreads: Bool { get }
    /// `diff.comments.list {root}`: the saved comments, oldest first.
    func listComments(root: String) async throws(AgentPaneGitFailure) -> JSONValue
    /// `diff.comments.save {root, comment}`: the stored record (the host owns id and dates).
    func saveComment(root: String, comment: JSONValue, key: String) async throws(AgentPaneGitFailure) -> JSONValue
    /// `diff.comments.delete {root, ids, versions}` → `{deleted, ids}`: a comment `versions` names
    /// goes only while its `updatedAt` is still that version, checked under the host's lock.
    func deleteComments(root: String, ids: [String], versions: [String: JSONValue], key: String) async throws(AgentPaneGitFailure) -> JSONValue
    /// `git.review.post {root, ids, versions}` → `{url, posted, in_body, cleared}`: a review
    /// worktree's drafts to GitHub as one review, with the person's gh; those still unchanged leave.
    func postReview(root: String, ids: [String], versions: [String: JSONValue], key: String) async throws(AgentPaneGitFailure) -> JSONValue
    /// `diff.comments.send {root, acp_session, ids, versions, text}` → `{sent, cleared}`: `text` to
    /// the acpmux session `acpSession` of the host's machine as one prompt whose id is `key`, then
    /// the comments still at `versions` leave the store. A resend under the same key runs once.
    func sendComments(root: String, acpSession: String, ids: [String], versions: [String: JSONValue],
                      text: String, key: String) async throws(AgentPaneGitFailure) -> JSONValue
    /// `diff.comments.send {root, acp_session, ids, threads: true, text?}`: sends unread thread items
    /// while keeping the stored comments.
    func sendThreadedComments(root: String, acpSession: String, ids: [String], text: String?, key: String)
        async throws(AgentPaneGitFailure) -> JSONValue
    /// `diff.comments.thread {root, id, reply?, author?, resolved?}`: mutates one stored thread.
    func threadComment(root: String, id: String, reply: String?, author: String?, resolved: Bool?, key: String)
        async throws(AgentPaneGitFailure) -> JSONValue
}

extension DiffCommentsStoring {
    public var supportsCommentThreads: Bool { false }

    public func sendThreadedComments(root: String, acpSession: String, ids: [String], text: String?, key: String)
        async throws(AgentPaneGitFailure) -> JSONValue {
        throw AgentPaneGitFailure.unsupported
    }

    public func threadComment(root: String, id: String, reply: String?, author: String?, resolved: Bool?, key: String)
        async throws(AgentPaneGitFailure) -> JSONValue {
        throw AgentPaneGitFailure.unsupported
    }
}

/// The diff tab's review comments (hq #7563): `cmux.diff.comments {method, params}` carries the
/// page's comment methods (webviews/src/comments/bridge.ts):
/// - `comments.list {repoRoot}` → `{comments, review?}` (`review`: the pull request a review
///   worktree's comments go to, `git.review.start`), `comments.save {repoRoot, comment}` → `{comment}`,
///   `comments.delete {repoRoot, id}`: the session host's store, for the tab's own repository only;
/// - `comments.send {repoRoot, ids, versions, text}`: `text` (every comment as one prompt) to the
///   chat that opened the tab, then those comments leave the store unless edited since
///   (`versions`: each id's `updatedAt` as sent); answers `{sent, cleared}`. It needs a real click or key, and the
///   page's opid is the prompt's id and the session host's idempotency key, so a resend is delivered once;
/// - `comments.post {repoRoot, ids, versions}`: a review worktree's drafts to GitHub as one review
///   (`git.review.post`), on a real click, the page's opid its key; answers the host's result.
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
                let listed = try await store.listComments(root: root)
                var reply: [String: JSONValue] = ["comments": .array(listed["comments"]?.arrayValue ?? [])]
                if let review = listed["review"], review.objectValue != nil { reply["review"] = review }
                return .object(reply)
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
                if inner["threads"]?.boolValue == true {
                    guard store.supportsCommentThreads else { throw PageError.unknownOp(method) }
                    return try await sendThreadedComments(inner, root: root, store: store, context: context)
                }
                return try await sendComments(inner, root: root, store: store, context: context)
            case "comments.thread":
                guard store.supportsCommentThreads else { throw PageError.unknownOp(method) }
                guard let id = inner["id"]?.stringValue else { throw PageError.invalidParams("id is required") }
                let reply = inner["reply"]?.stringValue
                let resolved = inner["resolved"]?.boolValue
                guard reply != nil || resolved != nil else { throw PageError.invalidParams("reply or resolved is required") }
                return try await store.threadComment(root: root, id: id, reply: reply,
                                                      author: inner["author"]?.stringValue, resolved: resolved, key: key)
            case "comments.post":
                // Posting publishes under the person's GitHub account: only their click does it.
                guard context.userGesture else {
                    throw PageError(code: "transport.gesture_required", message: "Posting needs a click or key in the page")
                }
                let ids = inner["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                guard !ids.isEmpty, ids.count <= Self.maximumSentComments else { throw PageError.invalidParams("ids are required") }
                return try await store.postReview(root: root, ids: ids, versions: inner["versions"]?.objectValue ?? [:], key: key)
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
        let versions = params["versions"]?.objectValue ?? [:]
        guard let deliver = chat.deliver else {
            // The session host hands the prompt to the chat on its own machine and clears the
            // comments in one keyed op.
            let sent: JSONValue
            do {
                sent = try await store.sendComments(root: root, acpSession: chat.session, ids: ids, versions: versions,
                                                    text: text, key: promptID)
            } catch {
                throw Self.sendError(error) ?? (remote ? remoteError(error) : Self.pageError(error))
            }
            return ["sent": sent["sent"] ?? .number(Double(ids.count)), "cleared": sent["cleared"] ?? .array([])]
        }
        guard await deliver(text, promptID) else {
            throw PageError(code: "cmux.diff.send_failed", message: "The chat did not take the comments")
        }
        // The chat has them: they leave the store, except one edited since the page sent it (its
        // `updatedAt` moved on), which stays for the next send. The host checks each version and
        // deletes in one step under its lock. A failed delete leaves them listed, never lost.
        let deleted = try await store.deleteComments(root: root, ids: ids, versions: versions, key: promptID + "-clear")
        let cleared = deleted["ids"]?.arrayValue ?? []
        return ["sent": .number(Double(ids.count)), "cleared": .array(cleared)]
    }

    private func sendThreadedComments(_ params: JSONValue, root: String, store: any DiffCommentsStoring,
                                      context: PageCallContext) async throws -> JSONValue {
        guard context.userGesture else {
            throw PageError(code: "transport.gesture_required", message: "Sending needs a click or key in the page")
        }
        let ids = params["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !ids.isEmpty, ids.count <= Self.maximumSentComments else { throw PageError.invalidParams("ids are required") }
        guard let chat = chat() else {
            throw PageError(code: "cmux.diff.no_chat", message: "No chat owns this diff")
        }
        do {
            return try await store.sendThreadedComments(root: root, acpSession: chat.session, ids: ids,
                                                        text: params["text"]?.stringValue,
                                                        key: context.opid ?? UUID().uuidString)
        } catch {
            throw Self.sendError(error) ?? (remote ? remoteError(error) : Self.pageError(error))
        }
    }

    /// The page's error for a send the session host refused: `cmux.diff.send_failed` when nothing
    /// went to the chat (no such session there, or acpmux refused), and a retryable
    /// `cmux.diff.send_unsettled` when the chat may have it. The page keeps the batch either way and
    /// sends it again under the same opid, which the host runs once. Nil for any other failure.
    static func sendError(_ failure: AgentPaneGitFailure) -> PageError? {
        guard failure.code == "operation.failed",
              let reason = failure.details.flatMap({ try? JSONValue.parse($0) })?["reason"]?.stringValue else { return nil }
        switch reason {
        case "no_session", "send_failed":
            return PageError(code: "cmux.diff.send_failed", message: "The chat did not take the comments")
        case "send_unsettled":
            return PageError(code: "cmux.diff.send_unsettled", message: "The chat may have taken the comments", retryable: true)
        default:
            return nil
        }
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
            if (commentStore as? any DiffCommentsStoring)?.supportsCommentThreads == true {
                payload["commentsThreads"] = true
            }
            members["payload"] = .object(payload)
        }
        return .object(members)
    }
}

extension DiffAgentGit: DiffCommentsStoring {
    public var supportsCommentThreads: Bool { link.supportsDiffCommentThreads }

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

    public func postReview(root: String, ids: [String], versions: [String: JSONValue], key: String) async throws(AgentPaneGitFailure) -> JSONValue {
        var params: [String: JSONValue] = ["root": .string(root), "ids": .array(ids.map(JSONValue.string))]
        if !versions.isEmpty { params["versions"] = .object(versions) }
        // Only the person posts: the host refuses it on any connection but the app's own.
        return try Self.mutationValue(
            try await link.userMutate("git.review.post", params: Data(JSONValue.object(params).compactText.utf8), idempotencyKey: key))
    }

    public func sendComments(root: String, acpSession: String, ids: [String], versions: [String: JSONValue],
                             text: String, key: String) async throws(AgentPaneGitFailure) -> JSONValue {
        let params: [String: JSONValue] = ["root": .string(root), "acp_session": .string(acpSession),
                                           "ids": .array(ids.map(JSONValue.string)), "text": .string(text),
                                           "versions": .object(versions)]
        return try await mutate("diff.comments.send", .object(params), key: key)
    }

    public func sendThreadedComments(root: String, acpSession: String, ids: [String], text: String?, key: String)
        async throws(AgentPaneGitFailure) -> JSONValue {
        var params: [String: JSONValue] = ["root": .string(root), "acp_session": .string(acpSession),
                                           "ids": .array(ids.map(JSONValue.string)), "threads": .bool(true)]
        if let text, !text.isEmpty { params["text"] = .string(text) }
        return try await mutate("diff.comments.send", .object(params), key: key)
    }

    public func threadComment(root: String, id: String, reply: String?, author: String?, resolved: Bool?, key: String)
        async throws(AgentPaneGitFailure) -> JSONValue {
        var params: [String: JSONValue] = ["root": .string(root), "id": .string(id)]
        if let reply { params["reply"] = .string(reply) }
        if let author { params["author"] = .string(author) }
        if let resolved { params["resolved"] = .bool(resolved) }
        return try await mutate("diff.comments.thread", .object(params), key: key)
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
