public import CmuxNextAgentPane
public import CmuxNextSettings
import CmuxNextWakeups
import Foundation
public import Observation

/// One stored comment and, once sent, its thread: the quote, the comment, "Sent", then the reply.
public nonisolated struct CommentThread: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable {
        /// Saved, not sent.
        case draft
        /// Sent (`sentIn`); the agent has not answered in the thread.
        case sent
        /// The agent answered in the thread; ``CommentThread/reply`` is its newest reply.
        case answered
    }

    public let id: String
    /// The record's `updatedAt`, the version a send names.
    public let version: JSONValue?
    /// `diff`, `browser` or `terminal`.
    public let surface: String
    /// A terminal comment's terminal tab id.
    public let terminalID: String?
    /// A terminal comment's scrollback rows (``CommentedTerminal/rows``), when it has them.
    public let terminalRows: ClosedRange<Int>?
    public let quote: String
    public let message: String
    public let state: State
    public let reply: String?

    /// The thread of a `diff.comments.list` record; nil for one with no id.
    public init?(_ record: JSONValue) {
        guard let id = record["id"]?.stringValue else { return nil }
        self.id = id
        version = record["updatedAt"]
        surface = record["surface"]?.stringValue ?? "diff"
        terminalID = record["terminal"]?["id"]?.stringValue
        terminalRows = CommentedTerminal.rows(of: record["terminal"]?["rows"])
        quote = record["quote"]?.stringValue ?? record["lineText"]?.stringValue ?? ""
        message = record["message"]?.stringValue ?? ""
        reply = Self.agentReply(of: record)
        state = reply != nil ? .answered : record["sentIn"]?.stringValue != nil ? .sent : .draft
    }

    /// The newest reply the agent wrote in a `diff.comments.list` record's thread (`replies`, author
    /// `agent`, from `cmux git comments reply`); nil before it answered.
    public static func agentReply(of record: JSONValue) -> String? {
        let replies = record["replies"]?.arrayValue ?? []
        return replies.last { $0["author"]?.stringValue == "agent" }?["text"]?.stringValue
    }
}

/// The terminal a comment is on: `terminal: {id, title, cwd, rows}` of its record.
public nonisolated struct CommentedTerminal: Sendable, Equatable {
    public let id: String
    public let title: String?
    public let cwd: String?
    /// The scrollback rows the selection covered (`rows: {first, last}`, the scrollbar's numbering:
    /// row 0 the oldest the terminal keeps), so the thread's card can show them again.
    public let rows: ClosedRange<Int>?

    public init(id: String, title: String?, cwd: String?, rows: ClosedRange<Int>? = nil) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.rows = rows
    }

    /// This terminal with the selection's `rows`.
    public func at(_ rows: ClosedRange<Int>?) -> Self {
        Self(id: id, title: title, cwd: cwd, rows: rows)
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["id": .string(id)]
        if let title, !title.isEmpty { object["title"] = .string(title) }
        if let cwd, !cwd.isEmpty { object["cwd"] = .string(cwd) }
        if let rows { object["rows"] = ["first": .number(Double(rows.lowerBound)), "last": .number(Double(rows.upperBound))] }
        return .object(object)
    }

    /// A record's `rows: {first, last}`; nil when absent or not a range.
    static func rows(of value: JSONValue?) -> ClosedRange<Int>? {
        guard let first = value?["first"]?.intValue, let last = value?["last"]?.intValue, first >= 0, last >= first else { return nil }
        return first...last
    }

    /// Where the prompt says the thread is: the title and the folder.
    var place: String {
        var out = title ?? ""
        if let cwd, !cwd.isEmpty { out += out.isEmpty ? cwd : " (\(cwd))" }
        return out
    }

    /// The thread's block in the prompt the chat gets: the selection as a Markdown block quote
    /// headed by the terminal, then the comment.
    public func prompt(quote: String, message: String) -> String {
        var heading = "Terminal"
        if let title, !title.isEmpty { heading += " · " + title }
        if let cwd, !cwd.isEmpty { heading += " (`\(cwd)`)" }
        var body = quote
        while body.hasSuffix("\n") || body.hasSuffix("\r") { body.removeLast() }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }
        var out = (["> **\(heading)**"] + lines).joined(separator: "\n")
        let note = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { out += "\n\n" + note }
        return out
    }
}

/// The comment threads of one root on one session host (`diff-comments-threads-v1`,
/// ``DiffCommentsStoring/supportsCommentThreads``): Comment… on a terminal selection saves it and
/// sends it to the workspace's chat in one threaded send; the agent answers in the thread
/// (`cmux git comments reply`), and ``threads`` is polled about every 2 s while any is "sent", so
/// that reply shows in the same thread. Resolve deletes it.
@MainActor
@Observable
public final class CommentThreadsModel {
    public let root: String
    @ObservationIgnored let store: any DiffCommentsStoring
    @ObservationIgnored let interval: Duration
    /// Every thread of ``root``, oldest first.
    public private(set) var threads: [CommentThread] = []
    /// Why the last save, send, list or resolve failed; nil after one that worked.
    public private(set) var failure: AgentPaneGitFailure?
    /// The next poll's deadline while a thread is "sent".
    @ObservationIgnored private let poll = DemandTimer(owner: "comment-threads.poll")

    public init(root: String, store: any DiffCommentsStoring, interval: Duration = .seconds(2)) {
        self.root = root
        self.store = store
        self.interval = interval
    }

    /// The threads on terminal `id`.
    public func threads(onTerminal id: String) -> [CommentThread] {
        threads.filter { $0.surface == "terminal" && $0.terminalID == id }
    }

    /// Saves `message` on `quote` of `terminal` and sends it to the acpmux session `acpSession` as
    /// one prompt whose id is `key` (a fresh opid: the session host runs a resend under it once).
    /// The comment stays as a thread; polling starts. Returns the thread.
    @discardableResult
    public func comment(on terminal: CommentedTerminal, quote: String, message: String, acpSession: String,
                        key: String) async throws(AgentPaneGitFailure) -> CommentThread {
        let record: JSONValue = ["surface": "terminal", "place": .string(terminal.place), "terminal": terminal.json,
                                 "quote": .string(quote), "message": .string(message),
                                 "submissionText": .string(terminal.prompt(quote: quote, message: message))]
        do throws(AgentPaneGitFailure) {
            let saved = try await store.saveComment(root: root, comment: record, key: key + "-save")
            guard let comment = saved["comment"], let thread = CommentThread(comment) else { throw AgentPaneGitFailure.failed }
            upsert(thread)
            do throws(AgentPaneGitFailure) {
                _ = try await store.sendThreadedComments(root: root, acpSession: acpSession, ids: [thread.id],
                                                         text: nil, key: key)
            } catch {
                // The send failed: the saved comment leaves the host too, so no later diff Send
                // takes it as a plain comment.
                _ = try? await store.deleteComments(root: root, ids: [thread.id], versions: [:], key: key + "-unsave")
                threads.removeAll { $0.id == thread.id }
                throw error
            }
            failure = nil
            await refresh()
            startPolling()
            return threads.first { $0.id == thread.id } ?? thread
        } catch {
            failure = error
            throw error
        }
    }

    /// Reads the threads again (`diff.comments.list`).
    public func refresh() async {
        do {
            let listed = try await store.listComments(root: root)
            threads = (listed["comments"]?.arrayValue ?? []).compactMap(CommentThread.init)
            failure = nil
        } catch {
            failure = error
        }
    }

    /// Resolves thread `id`: it leaves the store.
    public func resolve(_ id: String) async {
        do {
            _ = try await store.deleteComments(root: root, ids: [id], versions: [:], key: "resolve-" + UUID().uuidString)
            threads.removeAll { $0.id == id }
            failure = nil
        } catch {
            failure = error
        }
    }

    /// Whether a thread waits for its reply.
    public var isWaiting: Bool { threads.contains { $0.state == .sent } }

    /// Polls ``refresh()`` every ``interval`` while any thread is "sent"; one deadline at a time.
    public func startPolling() {
        guard isWaiting else { return }
        poll.scheduleIfIdle(after: interval) { [weak self] in
            await self?.pollOnce()
        }
    }

    private func pollOnce() async {
        await refresh()
        startPolling()
    }

    /// Stops polling (the last view of these threads closed).
    public func stopPolling() {
        poll.cancel()
    }

    /// Whether a poll deadline is pending.
    var isPolling: Bool { poll.isScheduled }

    private func upsert(_ thread: CommentThread) {
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[index] = thread
        } else {
            threads.append(thread)
        }
    }
}
