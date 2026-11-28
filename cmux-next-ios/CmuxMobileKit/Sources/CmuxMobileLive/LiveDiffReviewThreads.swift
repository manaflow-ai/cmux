import CmuxMobileModel
import CmuxMobileTransport
import Foundation

/// The diff review threads of a worktree on this Mac, over its daemon lane
/// (`diff.comments.list|thread|send`; cmux-mobile-host `policy.rs` forwards them only for a
/// worktree a tab of the Mac is in, a reply only by the reviewer, a send of the threads alone).
extension LiveWorkspaceCreationBackend: DiffReviewThreadsBackend {
    public func canReviewThreads(on macID: String) -> Bool {
        canManage(on: macID) && macID == sync.macID && sync.daemon != nil
    }

    public func reviewThreads(root: String, on macID: String) async throws -> [DiffReviewThread] {
        let client = try daemonClient(macID)
        do {
            // A read: the daemon refuses an idempotency key on it.
            let line = try await client.resourceRequest("diff.comments.list", params: Self.rootParams(root), deadline: .seconds(15))
            return DiffReviewThread.threads(fromList: try WorkspaceSync.checkResource(line))
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    public func reply(_ text: String, to thread: String, root: String, on macID: String) async throws {
        let client = try daemonClient(macID)
        try await resource(client, "diff.comments.thread", Self.replyParams(text, thread: thread, root: root),
                           key: "cmux-next-ios-thread-reply")
    }

    public func setResolved(_ resolved: Bool, thread: String, root: String, on macID: String) async throws {
        let client = try daemonClient(macID)
        try await resource(client, "diff.comments.thread", Self.resolveParams(resolved, thread: thread, root: root),
                           key: "cmux-next-ios-thread-resolve")
    }

    public func sendBack(_ threads: [DiffReviewThread], root: String, chat: String, on macID: String) async throws {
        guard !threads.isEmpty else { throw WorkspaceCreationError("No threads to send", isForPerson: true) }
        let client = try daemonClient(macID)
        try await resource(client, "diff.comments.send", Self.sendParams(threads, root: root, chat: chat),
                           key: "cmux-next-ios-thread-send")
    }

    nonisolated static func rootParams(_ root: String) -> [String: Any] { ["root": root] }

    /// A reply is always the reviewer's: a phone never answers as the agent.
    nonisolated static func replyParams(_ text: String, thread: String, root: String) -> [String: Any] {
        ["root": root, "id": thread, "reply": text, "author": "reviewer"]
    }

    nonisolated static func resolveParams(_ resolved: Bool, thread: String, root: String) -> [String: Any] {
        ["root": root, "id": thread, "resolved": resolved]
    }

    /// A threaded send: the ids, each at the version this phone read, and no prompt text (the
    /// session host writes it from the threads, so the agent's answers come back to them).
    nonisolated static func sendParams(_ threads: [DiffReviewThread], root: String, chat: String) -> [String: Any] {
        let threads = threads.prefix(500)
        var versions: [String: Any] = [:]
        for thread in threads where !thread.updatedAt.isEmpty { versions[thread.id] = thread.updatedAt }
        return ["root": root, "acp_session": chat, "ids": threads.map(\.id), "versions": versions, "threads": true]
    }
}
