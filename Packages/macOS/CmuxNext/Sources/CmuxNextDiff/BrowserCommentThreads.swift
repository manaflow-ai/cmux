public import CmuxNextAgentPane
public import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// A design mode comment on a browser page as the session host keeps it (`diff-comments-threads-v1`,
/// `surface: "browser"`): the page, the picked element and what the person wrote.
public nonisolated struct BrowserComment: Sendable, Equatable {
    /// The page's URL.
    public var url: String
    /// The page's title, when it has one.
    public var title: String?
    /// The picked element's selector.
    public var selector: String?
    /// The picked element's text (or the page's selection).
    public var quote: String?
    /// What the person wrote.
    public var message: String
    /// What the agent reads as the prompt: the design mode card's text.
    public var prompt: String

    public init(url: String, title: String? = nil, selector: String? = nil, quote: String? = nil, message: String, prompt: String) {
        self.url = url
        self.title = title
        self.selector = selector
        self.quote = quote
        self.message = message
        self.prompt = prompt
    }

    /// The `diff.comments.save` comment: `{surface: "browser", place, url, title?, selector?, quote?,
    /// message, submissionText}`; a threaded send's prompt names the thread by `place` and quotes
    /// `submissionText`, the design mode card's text.
    public var record: JSONValue {
        var value: [String: JSONValue] = ["surface": "browser", "place": .string(url), "url": .string(url),
                                          "message": .string(message), "submissionText": .string(prompt)]
        if let title, !title.isEmpty { value["title"] = .string(title) }
        if let selector, !selector.isEmpty { value["selector"] = .string(selector) }
        if let quote, !quote.isEmpty { value["quote"] = .string(quote) }
        return .object(value)
    }
}

/// One browser comment's thread as its page shows it: "Sending…", "Sent", then the agent's reply.
public nonisolated struct BrowserCommentThread: Sendable, Equatable {
    public enum State: String, Sendable {
        /// Saved or being sent; no answer from the host yet.
        case sending
        /// The chat took it (`sentIn`); the agent has not answered in the thread.
        case sent
        /// The agent answered in the thread (an `agent` reply).
        case answered
        /// Not sent.
        case failed
    }

    /// The session host's comment id; nil until the save answered.
    public var commentID: String?
    public var state: State
    /// The agent's reply text, once answered.
    public var reply: String?

    public init(commentID: String?, state: State, reply: String? = nil) {
        self.commentID = commentID
        self.state = state
        self.reply = reply
    }
}

/// Where a thread's design mode pick is: its browser tab's key and the element's selector.
public nonisolated struct BrowserCommentPick: Sendable, Equatable {
    public var tab: String
    public var selector: String

    public init(tab: String, selector: String) {
        self.tab = tab
        self.selector = selector
    }
}

/// Why a browser comment was not sent.
public nonisolated enum BrowserCommentSendFailure: Error, Sendable, Equatable {
    /// Sending needs a real click or key.
    case gestureRequired
    /// The host has no comment threads (`diff-comments-threads-v1`): the chip path stays.
    case threadsUnavailable
    /// The host refused or did not answer.
    case host(AgentPaneGitFailure)
}

/// Browser design mode comments sent to the agent as threads (cmuxterm-hq
/// goals/all-surface-comments-round-trip.md): one action saves the comment through the session
/// host's `diff.comments.save` with `surface: "browser"`, then a threaded `diff.comments.send` to the
/// workspace's chat; the thread then shows "Sent". The agent answers in the thread
/// (`cmux git comments reply`), and `diff.comments.list`, read about every 2 s while any thread is
/// sent, brings that reply. Resolve is `diff.comments.delete`.
///
/// Threads are keyed by the caller's key (the design mode card id), so a page shows each on its pick.
public final class BrowserCommentThreads {
    /// Each thread by its key.
    public private(set) var threads: [String: BrowserCommentThread] = [:]
    /// Called on every thread change; a nil thread is gone (resolved, or deleted elsewhere).
    public var onChange: ((String, BrowserCommentThread?) -> Void)?

    /// Where each thread lives: the host's store and the worktree root it is keyed by.
    private var homes: [String: (store: any DiffCommentsStoring, root: String)] = [:]
    /// Each thread's pick on its page, while the thread lasts.
    public private(set) var picks: [String: BrowserCommentPick] = [:]
    /// Per browser tab key, whether its pages were last told that sending is available.
    private var offered: [String: Bool] = [:]
    /// Nil: no polling of its own (tests call ``refresh()``).
    private let pollInterval: Duration?
    private let polling = DemandTimer(owner: "browser-comment-threads.poll")

    public init(pollInterval: Duration? = .seconds(2)) {
        self.pollInterval = pollInterval
    }

    /// The key of the thread whose pick is `pick`.
    public func key(of pick: BrowserCommentPick) -> String? {
        picks.first { $0.value == pick }?.key
    }

    /// Holds thread `key` for pick `pick` as "sending" at once, before its save, so the pick's chip and
    /// release paths see it while the send is under way.
    public func hold(_ key: String, pick: BrowserCommentPick) {
        picks[key] = pick
        update(key, BrowserCommentThread(commentID: nil, state: .sending))
    }

    /// Records that tab `tab` can (or cannot) send; true when that changed and the page must hear it.
    /// A nil `available` forgets the tab (design mode turned off).
    public func offer(_ available: Bool?, on tab: String) -> Bool {
        guard offered[tab] != available else { return false }
        offered[tab] = available
        return available != nil
    }

    /// ``send(_:key:store:root:acpSession:opid:userGesture:)`` for pick `pick`, on the worktree
    /// root of chat folder `folder` (its repository's root, read through `git`; else the folder).
    @discardableResult
    public func send<Git: DiffGitRunning & DiffCommentsStoring>(_ comment: BrowserComment, key: String, pick: BrowserCommentPick,
                                                                git: Git, folder: String?, acpSession: String,
                                                                opid: String) async throws(BrowserCommentSendFailure) -> BrowserCommentThread {
        hold(key, pick: pick)
        var root = folder ?? ""
        if let folder, let repository = try? await DiffPageRuntime.repository(at: URL(fileURLWithPath: folder, isDirectory: true), git: git) {
            root = repository.root
        }
        // Resolved while the root was read: nothing was saved, nothing goes.
        guard threads[key] != nil else { return BrowserCommentThread(commentID: nil, state: .failed) }
        guard root.hasPrefix("/") else {
            update(key, BrowserCommentThread(commentID: nil, state: .failed))
            throw .host(.failed)
        }
        do {
            return try await send(comment, key: key, store: git, root: root, acpSession: acpSession, opid: opid, userGesture: true)
        } catch {
            if threads[key]?.state == .sending { update(key, BrowserCommentThread(commentID: nil, state: .failed)) }
            throw error
        }
    }

    /// Whether any thread waits for the agent's reply.
    public var waiting: Bool { threads.values.contains { $0.state == .sent || $0.state == .sending } }

    /// Saves `comment` on `store` under the worktree `root` and sends it to the acpmux session
    /// `acpSession` as one prompt whose id is `opid` (the idempotency key), keeping it as a thread.
    /// - Returns: The thread, "sent" when the host threaded it.
    /// - Throws: ``BrowserCommentSendFailure``; a failure after the save leaves a "failed" thread.
    @discardableResult
    public func send(_ comment: BrowserComment, key: String, store: any DiffCommentsStoring, root: String,
                     acpSession: String, opid: String, userGesture: Bool) async throws(BrowserCommentSendFailure) -> BrowserCommentThread {
        guard userGesture else { throw .gestureRequired }
        guard store.supportsCommentThreads else { throw .threadsUnavailable }
        homes[key] = (store, root)
        if threads[key]?.state != .sending { update(key, BrowserCommentThread(commentID: nil, state: .sending)) }
        let saved: JSONValue
        do {
            saved = try await store.saveComment(root: root, comment: comment.record, key: opid + "-save")
        } catch {
            update(key, BrowserCommentThread(commentID: nil, state: .failed))
            throw .host(error)
        }
        guard let id = saved["comment"]?["id"]?.stringValue else {
            update(key, BrowserCommentThread(commentID: nil, state: .failed))
            throw .host(.failed)
        }
        // Resolved while it was saved: the comment leaves the host unsent.
        guard threads[key] != nil else { return await abandon(id, store: store, root: root) }
        do {
            let sent = try await store.sendThreadedComments(root: root, acpSession: acpSession, ids: [id], text: nil, key: opid)
            guard threads[key] != nil else { return await abandon(id, store: store, root: root) }
            let thread = BrowserCommentThread(commentID: id, state: (sent["sent"]?.intValue ?? 0) > 0 ? .sent : .failed)
            update(key, thread)
            poll()
            return thread
        } catch {
            // The send failed: the saved comment leaves the host too, so no later diff Send takes it
            // as a plain comment; the thread shows failed until resolved.
            // A send can fail "unsettled" (the chat may hold the prompt): its reply then has no thread.
            _ = await abandon(id, store: store, root: root)
            if threads[key] != nil { update(key, BrowserCommentThread(commentID: nil, state: .failed)) }
            throw .host(error)
        }
    }

    /// One `diff.comments.list` per store and root with a waiting thread: one the agent answered
    /// takes its reply; one the host no longer lists is gone.
    public func refresh() async {
        var asked: [String: JSONValue] = [:]
        for (key, thread) in threads where thread.state == .sent {
            guard let id = thread.commentID, let home = homes[key] else { continue }
            let place = "\(ObjectIdentifier(home.store).hashValue)|\(home.root)"
            if asked[place] == nil {
                guard let listed = try? await home.store.listComments(root: home.root) else { continue }
                asked[place] = listed["comments"] ?? .array([])
            }
            // The thread may have been resolved while the list was read.
            guard threads[key]?.commentID == id else { continue }
            guard let record = asked[place]?.arrayValue?.first(where: { $0["id"]?.stringValue == id }) else {
                drop(key)
                continue
            }
            if let reply = CommentThread.agentReply(of: record) {
                update(key, BrowserCommentThread(commentID: id, state: .answered, reply: reply))
            }
        }
    }

    /// Resolves thread `key`: its comment leaves the host (`diff.comments.delete`) and the thread goes.
    public func resolve(_ key: String) async throws(AgentPaneGitFailure) {
        guard let thread = threads[key] else { return }
        if let id = thread.commentID, let home = homes[key] {
            _ = try await home.store.deleteComments(root: home.root, ids: [id], versions: [:], key: UUID().uuidString)
        }
        drop(key)
    }

    /// Comment `id` of a thread resolved while it was being sent: deleted, its thread not brought back.
    private func abandon(_ id: String, store: any DiffCommentsStoring, root: String) async -> BrowserCommentThread {
        _ = try? await store.deleteComments(root: root, ids: [id], versions: [:], key: UUID().uuidString)
        return BrowserCommentThread(commentID: id, state: .failed)
    }

    /// Thread `key` is gone: its observers hear it while its pick is still known.
    private func drop(_ key: String) {
        threads[key] = nil
        homes[key] = nil
        onChange?(key, nil)
        picks[key] = nil
    }

    private func update(_ key: String, _ thread: BrowserCommentThread) {
        guard threads[key] != thread else { return }
        threads[key] = thread
        onChange?(key, thread)
    }

    /// Reads the list `pollInterval` from now, and again after each read while any thread is sent.
    private func poll() {
        guard let pollInterval, threads.values.contains(where: { $0.state == .sent }) else { return }
        polling.scheduleIfIdle(after: pollInterval) { @MainActor [weak self] in
            guard let self else { return }
            await refresh()
            poll()
        }
    }
}
