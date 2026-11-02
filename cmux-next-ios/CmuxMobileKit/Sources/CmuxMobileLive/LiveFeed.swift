import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "feed")

/// Turns acpmux watch events into Feed items and sends inline answers back
/// through the hub.
@MainActor
public final class LiveFeed: FeedActions {
    /// Where a session lives in the app (workspace and tab), when a tab is bound to it.
    public struct Place: Sendable {
        public var workspaceID: String
        public var tabID: String
        public var workspaceTitle: String
        public var tabTitle: String

        public init(workspaceID: String, tabID: String, workspaceTitle: String, tabTitle: String = "") {
            self.workspaceID = workspaceID
            self.tabID = tabID
            self.workspaceTitle = workspaceTitle
            self.tabTitle = tabTitle
        }
    }

    let store: FeedStore
    weak var hub: AcpmuxHub?
    /// Terminal agents' events (the daemon's notifications), read again on pull to refresh.
    weak var terminal: TerminalFeed?
    var place: @MainActor (String) -> Place?
    let now: @MainActor () -> Date
    /// The Mac this feed reads (`MacSession`): every item it makes names it.
    var macID: String?
    /// Open asks per session (resolved when the session reports none pending).
    private(set) var openAsks: [String: Set<String>] = [:]
    /// Every ask's session, by Feed item id.
    private var askSessions: [String: String] = [:]
    /// Every open ask's kind, by Feed item id.
    private var askKinds: [String: WorkspaceTab.WaitingFor] = [:]
    /// Each finished turn's whole reply, by Feed item id, read from the session's
    /// transcript (`LiveFeed+FullReply.swift`): a session summary's `preview` is only
    /// its first 160 characters with the line breaks flattened. Empty: read, and none found.
    var fullReplies: [String: String] = [:]
    /// The transcript read of each turn item whose reply is being read (one per item).
    var replyReads: [String: Task<Void, Never>] = [:]

    /// Whether `itemID` is an ask this feed put in the Feed (its Mac answers it).
    func owns(_ itemID: String) -> Bool { askSessions[itemID] != nil }

    /// What each session with open asks waits for: a question wins over a permission.
    public var waitingFor: [String: WorkspaceTab.WaitingFor] {
        openAsks.compactMapValues { asks in
            let kinds = Set(asks.compactMap { askKinds[$0] })
            return kinds.contains(.question) ? .question : kinds.contains(.permission) ? .permission : nil
        }
    }

    public init(store: FeedStore, hub: AcpmuxHub?, now: @escaping @MainActor () -> Date = Date.init,
                place: @escaping @MainActor (String) -> Place?) {
        self.store = store
        self.hub = hub
        self.place = place
        self.now = now
    }

    public func handle(_ event: AcpmuxHub.WatchEvent, sessions: [String: AcpmuxSession]) {
        switch event {
        case .permissionPending(let sessionID, let permissionID, let request):
            guard let mapped = AcpmuxRecords(sessionID: sessionID).permission(permissionID, request: request) else { return }
            let session = sessions[sessionID]
            let kind: FeedItem.Kind
            let markdown: String
            let waits: WorkspaceTab.WaitingFor
            switch mapped {
            case .question(let question):
                kind = .question(question)
                waits = .question
                markdown = question.summary
            case .permissionRequest(let permission):
                kind = .permission(permission)
                waits = .permission
                markdown = permission.toolCall.title.isEmpty ? "Permission requested" : "**Permission:** \(permission.toolCall.title)"
            default:
                return
            }
            let id = "ask-\(permissionID)"
            // This Mac answers the ask even when the Feed already lists it (read
            // again on a new link or a refresh), so its answer is routed here.
            openAsks[sessionID, default: []].insert(id)
            askSessions[id] = sessionID
            askKinds[id] = waits
            guard store.item(id: id) == nil else { return }
            log.info("feed ask \(id, privacy: .public)")
            store.upsert(item(id: id, kind: kind, sessionID: sessionID, session: session, markdown: markdown,
                              quote: session?.lastPrompt.map { FeedItem.Quote($0) }), atTop: true)
        case .sessionChanged(let session, let recordKind, let seq):
            if session.pendingPermissions == 0, let asks = openAsks.removeValue(forKey: session.id) {
                for id in asks { askKinds[id] = nil }
                for id in asks { store.resolveElsewhere(id, text: "Answered") }
            }
            guard recordKind == "turn_result" else { return }
            let item = turnItem(session, fallbackKey: "\(seq)", at: now())
            store.upsert(item, atTop: true)
            readFullReply(of: item, sessionID: session.id, turnID: session.lastTurnID, through: seq)
        case .permissionResolved:
            break
        case .sessionsLoaded(let sessions):
            hydrate(sessions)
        }
    }

    /// The watch reports only what happens after it starts, so a relaunched
    /// phone (or a new connection) would show an empty Feed while the Mac has
    /// history. Each session's last finished turn becomes its Feed item, with
    /// the same id a live `turn_result` uses, at the time the turn ended.
    func hydrate(_ sessions: [AcpmuxSession]) {
        let turns = sessions.compactMap { session -> (FeedItem, AcpmuxSession)? in
            guard session.lastTurnStatus != nil, let turnID = session.lastTurnID else { return nil }
            return (turnItem(session, fallbackKey: turnID, at: session.lastTurnEndedAt ?? session.updatedAt ?? now()), session)
        }
        log.info("feed history \(turns.count, privacy: .public) turns")
        store.mergeHistory(turns.map(\.0))
        // Replies of cards no longer in the Feed are let go.
        let shown = Set(store.items.map(\.id))
        fullReplies = fullReplies.filter { shown.contains($0.key) }
        for (item, session) in turns {
            readFullReply(of: item, sessionID: session.id, turnID: session.lastTurnID, through: session.lastSeq)
        }
    }

    /// A finished turn's item: keyed by the turn (live and history agree).
    func turnItem(_ session: AcpmuxSession, fallbackKey: String, at date: Date) -> FeedItem {
        let failed = session.lastTurnStatus == "failed"
        let stopped = session.lastTurnStatus == "cancelled"
        // A failed turn says why (the chat's failure sentence), not the preview: the preview is
        // the chat's last reply, which can be an earlier turn's.
        let failure = failed ? session.lastTurnError.map {
            TurnFailureCopy(message: $0, harness: session.harness, harnessName: DaemonTree.agentName(session.harness)).sentence
        } : nil
        let id = "turn-\(session.id)-\(session.lastTurnID ?? fallbackKey)"
        // The whole reply once read; until then the preview stands in for it.
        let markdown = failure ?? fullReplies[id].flatMap { $0.isEmpty ? nil : $0 } ?? session.preview.flatMap { $0.isEmpty ? nil : $0 }
            ?? (failed ? "The turn failed." : stopped ? "Stopped." : "Finished.")
        var item = item(id: id, kind: failed ? .failed : .response,
                        sessionID: session.id, session: session, markdown: markdown,
                        quote: session.lastPrompt.map { FeedItem.Quote($0) })
        item.createdAt = date
        return item
    }

    func item(id: String, kind: FeedItem.Kind, sessionID: String, session: AcpmuxSession?, markdown: String, quote: FeedItem.Quote?) -> FeedItem {
        let place = place(sessionID)
        let harness = session?.harness ?? "agent"
        var item = FeedItem(
            id: id, kind: kind, workspaceID: place?.workspaceID ?? "", tabID: place?.tabID ?? sessionID,
            agentName: session?.name.isEmpty == false ? session!.name : DaemonTree.agentName(harness), harness: harness,
            workspaceTitle: place?.workspaceTitle ?? (session?.cwd).map { ($0 as NSString).lastPathComponent } ?? "",
            markdown: markdown, quote: quote, createdAt: now()
        )
        item.macID = macID
        item.tabTitle = place?.tabTitle ?? ""
        return item
    }

    // MARK: FeedActions

    /// Pull to refresh: re-runs `_acpmux/watch` for the Mac's sessions, adds
    /// any finished turns the Feed missed, resolves asks the Mac no longer
    /// has, and reads each waiting session's open asks again.
    public func refresh() async throws {
        await terminal?.refresh()
        guard let hub else { throw AcpmuxConnection.RPCError(code: 0, message: "Not connected to your Mac", reason: nil) }
        let sessions = try await hub.wholeList("_acpmux/watch", ["enabled": .bool(true)], timeout: .seconds(20)).compactMap(AcpmuxSession.init)
        hydrate(sessions)
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for (sessionID, asks) in openAsks where (byID[sessionID]?.pendingPermissions ?? 0) == 0 {
            openAsks[sessionID] = nil
            for id in asks { askKinds[id] = nil }
            for id in asks { store.resolveElsewhere(id, text: "Answered") }
        }
        for session in sessions where session.pendingPermissions > 0 {
            let page = try await hub.request("_acpmux/events", .object([
                "sessionId": .string(session.id),
                "beforeSeq": .number(Double(session.lastSeq + 1)),
                "limit": .number(200),
                "kinds": .array([.string("permission_request"), .string("permission_decision")]),
            ]), timeout: .seconds(20))
            for (permissionID, request) in Self.openRequests(page["events"]?.arrayValue ?? []) {
                handle(.permissionPending(sessionID: session.id, permissionID: permissionID, request: request), sessions: byID)
            }
        }
    }

    /// Permission requests with no decision among `records`, in order.
    static func openRequests(_ records: [JSONValue]) -> [(permissionID: String, request: JSONValue)] {
        let decided = Set(records.compactMap { record -> String? in
            record["kind"]?.stringValue == "permission_decision" ? record["msg"]?["permissionId"]?.stringValue : nil
        })
        return records.compactMap { record in
            guard record["kind"]?.stringValue == "permission_request",
                  let id = record["msg"]?["permissionId"]?.stringValue, !decided.contains(id),
                  let request = record["msg"]?["request"] else { return nil }
            return (id, request)
        }
    }

    public func answer(_ item: FeedItem, question: AgentQuestion, with answer: AgentQuestionAnswer) async throws {
        guard let hub else { throw AcpmuxConnection.RPCError(code: 0, message: "Not connected", reason: nil) }
        try await hub.answer(question, with: answer)
    }

    public func decline(_ item: FeedItem, question: AgentQuestion) async throws {
        guard let hub else { throw AcpmuxConnection.RPCError(code: 0, message: "Not connected", reason: nil) }
        try await hub.decline(question)
    }

    public func respond(_ item: FeedItem, request: ACPPermissionRequest, option: ACPPermissionOption) async throws {
        guard let hub else { throw AcpmuxConnection.RPCError(code: 0, message: "Not connected", reason: nil) }
        try await hub.respond(sessionID: askSessions[item.id] ?? item.tabID, permissionID: request.id, optionID: option.id)
    }

    public func message(for error: any Error) -> String {
        AcpmuxSessionSource.message(error)
    }

    /// acpmux answers a decided (or withdrawn) ask with not-found "no pending permission <id>".
    public func isAlreadyAnswered(_ error: any Error) -> Bool {
        guard let error = error as? AcpmuxConnection.RPCError else { return false }
        return error.message.hasPrefix("no pending permission")
    }
}
