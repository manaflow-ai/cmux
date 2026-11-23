import CmuxMobileAgentChat
import CmuxMobileChief
import Foundation
import Observation

// Auto chats on the phone (`plans/cmux-next/auto-mode/DESIGN.md`, slice E): the account's Auto
// chats, read and sent to through the Cloud service with no Mac. The requests, the paging, the
// held wait, the retries and what a chat's records are come from Rust (`cmux-mobile-auto`,
// through `cmux-mobile-link-ffi`'s `AutoChats`); this file turns its answers into the list's rows
// and the chat view's events.

/// Where an Auto chat is, as the list and the chat say it.
public enum AutoChatPlace: String, Hashable, Sendable {
    /// A Cloud machine runs it.
    case cloud
    /// A Cloud machine is taking it.
    case resuming
    /// A Cloud machine runs it and gives it back to a Mac when the turn ends.
    case comingBack = "coming_back"
    /// A Mac runs it.
    case onMac = "on_mac"
    /// Nothing runs it now.
    case idle
    /// It waits for a Cloud machine the account does not have.
    case noMachine = "no_machine"

    /// The one line that says where the chat is, in the Mac's words; nil when nothing runs it.
    public var line: String? {
        switch self {
        case .cloud, .comingBack: AutoChatWords.runningInCloud
        case .resuming: AutoChatWords.resuming
        case .onMac: AutoChatWords.onMac
        case .noMachine: AutoChatWords.needsMachine
        case .idle: nil
        }
    }

    /// What goes under ``line``: a chat that comes back to a Mac says when.
    public var hint: String? {
        self == .comingBack ? AutoChatWords.comingBack : nil
    }
}

/// The repository and branch an Auto chat works in.
public struct AutoChatRepo: Hashable, Identifiable, Sendable {
    public var remote: String
    public var branch: String

    public init(remote: String, branch: String) {
        self.remote = remote
        self.branch = branch
    }

    init?(_ value: JSONValue?) {
        guard let remote = value?["remote"]?.stringValue, let branch = value?["branch"]?.stringValue else { return nil }
        self.init(remote: remote, branch: branch)
    }

    public var id: String { remote + "\u{1}" + branch }

    /// The remote's last two parts (`owner/name`), for a row.
    public var name: String {
        var path = remote
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == ":" }).suffix(2)
        return parts.isEmpty ? remote : parts.joined(separator: "/")
    }
}

/// One Auto chat in the list.
public struct AutoChatRow: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var harness: String
    public var place: AutoChatPlace
    public var keepInCloud: Bool
    /// A Cloud machine has the chat, or is taking it.
    public var inCloud: Bool
    public var repo: AutoChatRepo?
    public var closed: Bool

    public init(id: String, title: String, harness: String = "claude", place: AutoChatPlace, keepInCloud: Bool = false,
                inCloud: Bool = false, repo: AutoChatRepo? = nil, closed: Bool = false) {
        self.id = id
        self.title = title
        self.harness = harness
        self.place = place
        self.keepInCloud = keepInCloud
        self.inCloud = inCloud
        self.repo = repo
        self.closed = closed
    }

    /// A row as Rust writes it (`cmux_mobile_auto::rows::ChatRow`); nil for anything else.
    init?(_ value: JSONValue?) {
        guard let value, let id = value["id"]?.stringValue,
              let place = value["place"]?.stringValue.flatMap(AutoChatPlace.init(rawValue:)) else { return nil }
        self.init(id: id, title: value["title"]?.stringValue ?? "", harness: value["harness"]?.stringValue ?? "",
                  place: place, keepInCloud: value["keepInCloud"] == .bool(true), inCloud: value["inCloud"] == .bool(true),
                  repo: AutoChatRepo(value["repo"]), closed: value["closed"] == .bool(true))
    }

    /// The row's name: the chat's title, else its repository, else "New Chat".
    public var name: String {
        if !title.isEmpty { return title }
        return repo?.name ?? AutoChatWords.newChat
    }
}

/// Why a call about Auto chats did not answer.
public enum AutoChatFailure: Error, Equatable, Sendable {
    /// No answer arrived.
    case unreachable
    /// The Cloud service refused the call.
    case refused(status: Int, code: String)
    /// An answer this build cannot read.
    case unreadable
}

/// The account's Auto chats. Every answer is the JSON text Rust wrote (`cmux-mobile-link-ffi`
/// `auto_chats.rs` names the shapes).
public protocol AutoChatService: Sendable {
    /// `{chats: [row], repos: [{remote, branch}], more}`.
    func list() async throws -> String
    /// Whether the account has a Cloud machine for Auto chats to run on.
    func hasMachine() async throws -> Bool
    /// `{outcome: "chat", chat: row}`, `{outcome: "no_machine"}` or `{outcome: "incomplete"}`.
    /// The same `messageID` again reaches the chat the first call made.
    func start(remote: String, branch: String, messageID: String, text: String) async throws -> String
    /// One chat, to read.
    func line(id: String) -> any AutoChatLine
}

/// One open Auto chat. Every answer is a batch: `{chat: row, records: [record], caughtUp, ended,
/// retryAfterMs}`.
public protocol AutoChatLine: AnyObject, Sendable {
    /// The next records. The first call opens the chat; a later one is held until the chat
    /// changes. A call that got no answer answers a batch with `retryAfterMs`, and the next call
    /// waits that long itself.
    func next() async throws -> String
    /// Sends `text` under `messageID`; the same id again is not a second message.
    func send(messageID: String, text: String) async throws -> String
    func keep(_ keepInCloud: Bool) async throws -> String
    /// The reader left: a held `next` answers `ended`.
    func close()
}

/// One answer of an ``AutoChatLine``.
struct AutoChatBatch {
    var chat: AutoChatRow?
    var records: [JSONValue]
    var caughtUp: Bool
    var ended: Bool
    /// The read got no answer.
    var offline: Bool

    init?(json: String) {
        guard let value = JSONValue(jsonData: Data(json.utf8)) else { return nil }
        chat = AutoChatRow(value["chat"])
        records = value["records"]?.arrayValue ?? []
        caughtUp = value["caughtUp"] == .bool(true)
        ended = value["ended"] == .bool(true)
        offline = value["retryAfterMs"]?.numberValue != nil
    }
}

/// The account's Auto chats: the list, the repositories a new chat can start in, and the chat
/// that is open.
@MainActor
@Observable
public final class AutoChatsModel {
    public enum Phase: Equatable, Sendable { case idle, loading, loaded, failed }

    /// What starting a chat came to.
    public enum Started: Equatable, Sendable {
        case chat(AutoChatRow)
        /// The account has no Cloud machine for Auto chats.
        case noMachine
        case failed
    }

    /// An open chat: what reads it, and the store the chat view draws.
    public struct Open {
        public let source: AutoChatSource
        public let store: AgentChatStore
    }

    /// The account's open Auto chats, newest first.
    public private(set) var chats: [AutoChatRow] = []
    /// The repositories and branches those chats work in, the most recently used first.
    public private(set) var repos: [AutoChatRepo] = []
    public private(set) var phase: Phase = .idle
    /// Whether the account has a Cloud machine for Auto chats; nil until it was read.
    public private(set) var hasMachine: Bool?

    @ObservationIgnored private let service: any AutoChatService
    /// The one chat that is read now: opening another ends this one's requests.
    @ObservationIgnored private var open: Open?
    /// The chats this phone started here: each opens as starting until its first message shows.
    @ObservationIgnored private var startedHere: Set<String> = []

    public init(service: any AutoChatService) {
        self.service = service
    }

    /// Reads the list. The rows already shown stay while it reads and when it fails.
    public func load() async {
        if phase != .loaded { phase = .loading }
        do {
            let json = try await service.list()
            guard let value = JSONValue(jsonData: Data(json.utf8)), let rows = value["chats"]?.arrayValue else {
                phase = .failed
                return
            }
            chats = rows.compactMap { AutoChatRow($0) }.filter { !$0.closed }
            repos = (value["repos"]?.arrayValue ?? []).compactMap { AutoChatRepo($0) }
            phase = .loaded
        } catch {
            phase = .failed
        }
    }

    /// Reads whether the account has a Cloud machine for Auto chats (the New Chat sheet asks).
    public func readMachine() async {
        if let has = try? await service.hasMachine() { hasMachine = has }
    }

    /// Starts a chat in `repo` with a first message. `messageID` is made once per message, so
    /// sending the same sheet again reaches the same chat.
    public func start(repo: AutoChatRepo, text: String, messageID: String) async -> Started {
        guard let json = try? await service.start(remote: repo.remote, branch: repo.branch, messageID: messageID, text: text),
              let value = JSONValue(jsonData: Data(json.utf8)) else { return .failed }
        switch value["outcome"]?.stringValue {
        case "chat":
            guard let row = AutoChatRow(value["chat"]) else { return .failed }
            hasMachine = true
            startedHere.insert(row.id)
            if !chats.contains(where: { $0.id == row.id }) { chats.insert(row, at: 0) }
            return .chat(row)
        case "no_machine":
            hasMachine = false
            return .noMachine
        default:
            return .failed
        }
    }

    /// The chat `row`, open. One chat is read at a time.
    public func chat(_ row: AutoChatRow) -> Open {
        if let open, open.source.row.id == row.id { return open }
        let source = AutoChatSource(row: row, service: service, starting: startedHere.contains(row.id)) { [weak self] row in
            self?.changed(row)
        }
        let store = AgentChatStore(source: source)
        let opened = Open(source: source, store: store)
        open?.source.close()
        open = opened
        return opened
    }

    /// The person left the open chat: its held request ends. Opening it again reads it anew.
    public func leave() {
        open?.source.close()
        open = nil
    }

    /// The open chat said where it is now: its row says the same.
    private func changed(_ row: AutoChatRow) {
        guard let index = chats.firstIndex(where: { $0.id == row.id }), chats[index] != row else { return }
        chats[index] = row
    }
}

/// One Auto chat as the chat view reads it: the records the Cloud service keeps for it, mapped
/// the way a Cloud chat's are (``AcpmuxRecords``), and the person's messages sent to its inbox.
///
/// A phone only reads and sends: a permission prompt, a question or a mode shows, and is answered
/// where the chat runs.
@MainActor
@Observable
public final class AutoChatSource: AgentSessionSource {
    public private(set) var summary: AgentSessionSummary
    /// The chat as the Cloud service last described it.
    public private(set) var row: AutoChatRow
    /// Auto was switched off for the chat, or it was started over: nothing more arrives.
    public private(set) var ended = false
    /// The Cloud service refused to read the chat.
    public private(set) var unavailable = false
    /// A Keep in Cloud change did not go through.
    public var keepFailed = false
    /// The last read got no answer.
    public private(set) var isOffline = false
    /// This phone started the chat and its first message is not in the transcript yet.
    public private(set) var awaitsFirstPrompt: Bool
    public let loadsHistory = true

    @ObservationIgnored private let service: any AutoChatService
    @ObservationIgnored private let records: AcpmuxRecords
    @ObservationIgnored private let changed: @MainActor (AutoChatRow) -> Void
    @ObservationIgnored private var line: (any AutoChatLine)?
    @ObservationIgnored private var continuation: AsyncStream<AgentSessionEvent>.Continuation?
    @ObservationIgnored private var caughtUp = false

    init(row: AutoChatRow, service: any AutoChatService, starting: Bool = false,
         changed: @escaping @MainActor (AutoChatRow) -> Void) {
        self.row = row
        self.service = service
        self.changed = changed
        awaitsFirstPrompt = starting
        records = AcpmuxRecords(sessionID: row.id)
        summary = AgentSessionSummary(id: row.id, name: row.name, harness: row.harness, agentName: row.harness,
                                      cwd: "", workspaceTitle: row.repo?.name ?? "", macName: AutoChatWords.cloud,
                                      branch: row.repo?.branch, status: .ready)
    }

    /// The chat from its first record, then what arrives. A second reader replaces the first.
    public func events() -> AsyncStream<AgentSessionEvent> {
        line?.close()
        continuation?.finish()
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        let line = service.line(id: row.id)
        self.line = line
        self.continuation = continuation
        caughtUp = false
        // The reader left (the chat view closed): the held request ends.
        continuation.onTermination = { _ in line.close() }
        Task { [weak self] in
            while let self, self.line === line, !self.ended, !self.unavailable {
                guard let json = try? await line.next(), let batch = AutoChatBatch(json: json) else {
                    self.refused(line)
                    return
                }
                self.apply(batch, from: line)
            }
        }
        return stream
    }

    /// The reader left: the held request ends, and nothing more is read or drawn.
    func close() {
        line?.close()
        line = nil
        continuation?.finish()
        continuation = nil
    }

    public func send(_ intent: AgentClientIntent) {
        guard case let .prompt(text, attachments, _, promptID, _) = intent else {
            continuation?.yield(.clientError(AutoChatWords.textOnly))
            return
        }
        guard attachments.isEmpty else {
            continuation?.yield(.promptNotSent(text: text, attachments: attachments, promptID: promptID, reason: AutoChatWords.textOnly))
            return
        }
        guard let line, !ended, !unavailable else {
            continuation?.yield(.promptNotSent(text: text, attachments: [], promptID: promptID, reason: AutoChatWords.notSent))
            return
        }
        Task { [weak self] in
            // The prompt's id is the message's id: sent again, the Cloud service takes it once.
            let json = try? await line.send(messageID: promptID, text: text)
            guard let self, self.line === line else { return }
            guard let json, let batch = AutoChatBatch(json: json) else {
                self.continuation?.yield(.promptNotSent(text: text, attachments: [], promptID: promptID, reason: AutoChatWords.notSent))
                return
            }
            self.apply(batch, from: line)
        }
    }

    /// Keeps the chat in the Cloud when a Mac returns, or stops keeping it. The row shows the
    /// choice at once and goes back if the change does not go through.
    public func keepInCloud(_ keep: Bool) {
        guard let line, row.keepInCloud != keep else { return }
        let before = row
        var chosen = row
        chosen.keepInCloud = keep
        show(chosen)
        Task { [weak self] in
            let json = try? await line.keep(keep)
            guard let self, self.line === line else { return }
            guard let json, let batch = AutoChatBatch(json: json) else {
                self.show(before)
                self.keepFailed = true
                return
            }
            self.apply(batch, from: line)
        }
    }

    private func apply(_ batch: AutoChatBatch, from line: any AutoChatLine) {
        guard self.line === line, let continuation else { return }
        if let chat = batch.chat { show(chat) }
        if batch.offline != isOffline {
            isOffline = batch.offline
            continuation.yield(.status(batch.offline ? .disconnected : .ready))
        }
        let events = batch.records.flatMap { records.map($0) }
        if !events.isEmpty {
            if awaitsFirstPrompt { awaitsFirstPrompt = false }
            continuation.yield(.batch(events))
        }
        if batch.caughtUp, batch.chat != nil, !caughtUp {
            caughtUp = true
            continuation.yield(.historyLoading(false))
        }
        if batch.ended, !ended {
            ended = true
            continuation.yield(.historyLoading(false))
            continuation.yield(.status(.closed))
        }
    }

    /// The Cloud service refused the chat (it is gone, or not this account's).
    private func refused(_ line: any AutoChatLine) {
        guard self.line === line else { return }
        unavailable = true
        continuation?.yield(.historyLoading(false))
        continuation?.yield(.clientError(AutoChatWords.unavailable))
        continuation?.yield(.status(.closed))
    }

    private func show(_ row: AutoChatRow) {
        guard row != self.row else { return }
        self.row = row
        if summary.name != row.name { summary.name = row.name }
        changed(row)
    }
}
