import CmuxConversationCore
import CmuxMobileTransport
import Foundation
import Observation

/// Markdown to one plain line, as a list preview: the rows, Chief's pin
/// bubble and its VoiceOver label (F4).
func plainPreview(_ markdown: String) -> String {
    markdown
        .replacingOccurrences(of: "```[a-z]*", with: "", options: .regularExpression)
        .replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

/// A conversation of the Mac's Home list other than the Mac Chief's: pushed
/// as that conversation over the Mac's `chief` channel.
public struct MacConversationRoute: Hashable, Sendable {
    public let conversationID: String
    /// The Chief's agent id (a `chief` row), else nil.
    public let chief: String?
    public let title: String
}

/// One or two letters for a name's monogram ("Build Bot" → "BB").
func homeInitials(_ name: String) -> String {
    let words = name.split(whereSeparator: \.isWhitespace)
    let letters = String(words.prefix(2).compactMap(\.first)).uppercased()
    return letters.isEmpty ? "?" : letters
}

/// One row of the Mac's Home list, as the Mac's conversation owner derives it
/// (cmux-tui spec `home-inbox`, `home-inbox-v1`): the same rows the Mac's Home
/// sidebar draws (`HomeInboxSource` → `HomeSidebarModel` in CmuxNext), field
/// for field. The phone keeps no rules of its own for kind, name, order,
/// pins, unread or the Chief's state, so its Home cannot drift from the Mac's.
public struct MacHomeRow: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case chief, direct, channel, group }
    public enum ChiefState: String, Sendable { case working, waiting, idle }

    public let id: String
    public let kind: Kind
    /// The owner's name: a Chief's registry name, else the title, else the people.
    public let name: String
    public let unread: Int
    public let activityAt: Date
    /// The newest message as one plain line (an agent's Markdown without its markers, as the Mac draws it).
    public let preview: String
    /// The Chief's agent id (a `chief` row).
    public let chief: String?
    public let chiefState: ChiefState?
    public let isPinned: Bool
    public let pinPosition: UInt64?
    /// The person's Mark as Unread.
    public let markedUnread: Bool
    public let isMuted: Bool

    /// Unread messages, or the person's Mark as Unread (then at least one), as on the Mac.
    public var unreadCount: Int { max(unread, markedUnread ? 1 : 0) }
    /// The Chief types or runs: its tile and row show the typing bubble.
    public var isWorking: Bool { chiefState == .working }
    /// The row's title: the owner's name, else Untitled (the Mac's fallback).
    public var title: String { name.isEmpty ? String(localized: "Untitled") : name }

    /// The rows of a `home-inbox` reply's `data`, in the owner's order.
    public static func rows(fromHomeInbox data: [String: Any]) -> [MacHomeRow] {
        (data["rows"] as? [[String: Any]] ?? []).compactMap(MacHomeRow.init(wire:))
    }

    init?(wire object: [String: Any]) {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        // A Cloud row never crosses the link; one from an older owner would be the Mac's Cloud inbox.
        guard (object["owner"] as? String ?? "local") == "local" else { return nil }
        self.id = id
        kind = Kind(rawValue: object["kind"] as? String ?? "") ?? .group
        name = object["name"] as? String ?? ""
        unread = (object["unread"] as? NSNumber)?.intValue ?? 0
        activityAt = Self.time(object["activity_at"] as? String) ?? .distantPast
        // A Chief's failure note reads as the conversation shows it, not in operator
        // words (only in a Chief's conversation: the brain posts it there).
        let wirePreview = object["preview"] as? String ?? ""
        preview = plainPreview(object["chief"] is String || kind == .chief ? ChiefTurnFailure.previewText(wirePreview) : wirePreview)
        chief = object["chief"] as? String
        chiefState = (object["chief_state"] as? String).flatMap(ChiefState.init(rawValue:))
        isPinned = object["pinned"] as? Bool ?? false
        pinPosition = (object["pin_position"] as? NSNumber)?.uint64Value
        markedUnread = object["marked_unread"] as? Bool ?? false
        isMuted = object["muted"] as? Bool ?? false
    }

    /// RFC 3339, with or without a fraction.
    static func time(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// The Mac's Home list as its sidebar lays it out (`HomeSidebarModel`, MessagesLab's
/// `SidebarView`): every pinned conversation in the grid, in the owner's pin order, then
/// every other conversation in the owner's order (newest first). A search or the Unread
/// toggle (the Mac's only filter) hides the grid and lists the matching conversations in
/// the list's order, pinned ones first. A search matches the name or the preview
/// (`home-inbox` rows carry no member names, so a member's name does not match here).
public struct MacHomeList: Equatable, Sendable {
    public private(set) var pinned: [MacHomeRow]
    public private(set) var rows: [MacHomeRow]

    public init(_ all: [MacHomeRow], query: String = "", unreadOnly: Bool = false) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = all.filter { row in
            (!unreadOnly || row.unreadCount > 0)
                && (needle.isEmpty || row.title.localizedStandardContains(needle) || row.preview.localizedStandardContains(needle))
        }
        let pinnedRows = shown.filter(\.isPinned)
        let rest = shown.filter { !$0.isPinned }
        if needle.isEmpty, !unreadOnly {
            pinned = pinnedRows
            rows = rest
        } else {
            pinned = []
            rows = pinnedRows + rest
        }
    }

    public var isEmpty: Bool { pinned.isEmpty && rows.isEmpty }
}

/// The chosen Mac's Home list over its link: a `chief` channel of its own
/// (cmux-mobile-host scopes it to the owner's conversations with agents and to
/// the local owner's rows), read with `home-inbox` and read again (coalesced)
/// after each conversation or list-state event, as the Mac's `HomeInboxSource`
/// does. Pin, Unpin and the unread mark are the person's list state on that
/// owner (`conversation-inbox-op`), so the Mac's Home changes with them.
@MainActor
@Observable
public final class MacHomeFeed {
    // The rows are re-read on conversation, typing and list-state events. A Chief run
    // that starts without a message or typing (`conversation-run-changed`) is not
    // forwarded over the link, so its typing shows with its next message or typing.
    public static let shared = MacHomeFeed()

    /// The owner's rows in its order; nil until the first read of this Mac.
    public private(set) var rows: [MacHomeRow]?
    /// The Mac these rows are from.
    public private(set) var macID: String?
    /// Why the list could not be read (the Mac's own words), nil after a read.
    public private(set) var problem: String?

    @ObservationIgnored private var client: DaemonClient?
    /// The Mac's link, for a conversation opened from the list (its own channel).
    @ObservationIgnored private var link: (any MacLink)?
    /// Conversations opened from the list on this Mac, by id.
    @ObservationIgnored private var sessions: [String: ChiefSession] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var readAgain = false
    /// List-state writes not answered yet: a read meanwhile could undo the edit shown.
    @ObservationIgnored private var pendingWrites = 0
    /// Each conversation's newest seq (`conversation-list`), for Mark as Read.
    @ObservationIgnored private var lastSeq: [String: Int] = [:]
    // task-owner: the event reader of the current channel, cancelled with it
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    public init() {}

    /// The Mac Chief's own conversation on this Mac (the oldest with the owner and `agent_mux`,
    /// as the Mac's Home picks it), from the owner's list: its row is the Mac Chief.
    public private(set) var macChiefID: String?

    /// The Home list of the Mac behind `link` (a new link, or another Mac):
    /// opens its own `chief` channel and reads the list. Another Mac's rows
    /// are dropped at once, so they never show under this Mac; conversations
    /// opened on the last link close (their channels were on it).
    public func connect(link: any MacLink, macID: String?) async {
        if macID != self.macID {
            rows = nil
            macChiefID = nil
            lastSeq = [:]
        }
        self.macID = macID
        self.link = link
        // Conversations opened on the last link were on its channels.
        closeSessions()
        opening = true
        await open(link)
        opening = false
    }

    /// Opens the list's channel on `link` and reads the list; a failure leaves the
    /// channel closed and the next ``refresh()`` tries again on the same link.
    private func open(_ link: any MacLink) async {
        generation += 1
        let mine = generation
        problem = nil
        let old = detach()
        await old?.close()
        var opened: DaemonClient?
        do {
            let channel = try await link.openChannel(service: ChiefDaemonBackend.service, args: [:])
            let client = DaemonClient(channel: channel)
            opened = client
            guard mine == generation else {
                await client.close()
                return
            }
            // The list first: the channel's filter learns the scope from it.
            try await listed(client)
            _ = try await client.request("subscribe")
            guard mine == generation else {
                await client.close()
                return
            }
            self.client = client
            eventTask = Task { [weak self] in
                for await line in client.events {
                    guard let self else { return }
                    self.note(line)
                }
                // The channel ended under us: the next refresh opens it again.
                guard let self, mine == self.generation else { return }
                self.client = nil
            }
            refresh()
        } catch {
            await opened?.close()
            guard mine == generation else { return }
            problem = Self.reason(error)
        }
    }

    /// A conversation of the list other than the Mac Chief's, over its own
    /// `chief` channel to this Mac (the channel's filter allows only
    /// conversations between the owner and agents, which is every row). It
    /// stays open (with its outbox) until the link or the Mac changes; a screen
    /// showing it then asks again (``sessionEpoch``).
    public func session(for route: MacConversationRoute) async throws -> ChiefSession {
        if let session = sessions[route.conversationID] { return session }
        guard let link else { throw LinkError(code: "offline", message: String(localized: "Your Mac isn't connected.")) }
        let mine = generation
        let channel = try await link.openChannel(service: ChiefDaemonBackend.service, args: [:])
        let client = DaemonClient(channel: channel)
        do {
            // The channel's scope comes from the owner's list; the conversation's agent from its summary.
            let list = try await Self.call(client, "conversation-list", [:])
            guard mine == generation else { throw LinkError(code: "offline", message: String(localized: "The Mac's link changed.")) }
            if let session = sessions[route.conversationID] {
                await client.close()
                return session
            }
            let summary = (list["conversations"] as? [[String: Any]] ?? []).first { $0["id"] as? String == route.conversationID }
            let agent = route.chief ?? (summary?["participants"] as? [[String: Any]] ?? [])
                .first { $0["kind"] as? String == "agent" }?["id"] as? String
            let identity = ChiefIdentity(chiefID: agent ?? "agent_unknown", title: route.title,
                                         avatar: homeInitials(route.title))
            let backend = ChiefDaemonBackend(client: client, identity: identity, conversationID: route.conversationID)
            let session = ChiefSession(backend: backend, identity: identity, outbox: ChiefOutbox(file: nil))
            session.macID = macID
            sessions[route.conversationID] = session
            return session
        } catch {
            await client.close()
            throw error
        }
    }

    /// Bumped each time the opened conversations close (a new link or another Mac):
    /// a conversation's screen asks for its session again.
    public private(set) var sessionEpoch = 0

    private func closeSessions() {
        guard !sessions.isEmpty else { return }
        for session in sessions.values { session.backend.close() }
        sessions = [:]
        sessionEpoch += 1
    }

    /// Chief on `macID` is not reachable. Its list stays (it is read on its
    /// own channel, as the Mac keeps its list while the owner reconnects);
    /// another Mac's list goes at once, so it never shows under this Mac.
    public func forget(unless macID: String?) {
        guard macID != self.macID else { return }
        generation += 1
        rows = nil
        problem = nil
        macChiefID = nil
        lastSeq = [:]
        closeSessions()
        self.macID = macID
        link = nil
        let old = detach()
        Task { await old?.close() }
    }

    /// Ends the current channel's state now (a later connect never meets it) and hands back its client to close.
    private func detach() -> DaemonClient? {
        eventTask?.cancel()
        eventTask = nil
        let old = client
        client = nil
        reading = false
        readAgain = false
        needsRelist = false
        pendingWrites = 0
        return old
    }

    /// Owner events after which the rows are read again: a message or summary
    /// change, Chief typing, and the person's list state.
    static let rowEvents: Set<String> = ["conversation-changed", "conversation-typing", "conversation-inbox-changed", "overflow"]

    private func note(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String, Self.rowEvents.contains(event) else { return }
        // A new or changed conversation can widen the scope: the list again first.
        let summaryChanged = (object["change"] as? [String: Any])?["kind"] as? String == "conversation"
        refresh(relist: summaryChanged || event == "overflow")
    }

    /// Reads the rows: one read at a time, and a request during a read runs one more after it.
    public func refresh() { refresh(relist: false) }

    private func refresh(relist: Bool) {
        guard let client else {
            // No channel (it failed or ended) while the link is up: open it again.
            if let link, !opening {
                opening = true
                Task { [weak self] in
                    await self?.open(link)
                    self?.opening = false
                }
            }
            return
        }
        if relist { needsRelist = true }
        if reading { readAgain = true; return }
        reading = true
        let mine = generation
        // task-owner: one home-inbox read (and one more per request made during it); ends with its reply
        Task { [weak self] in
            defer { if let self, mine == self.generation { self.reading = false } }
            while let self, mine == self.generation {
                self.readAgain = false
                let relist = self.needsRelist
                self.needsRelist = false
                do {
                    if relist { try await self.listed(client) }
                    let data = try await Self.call(client, "home-inbox", ["owners": ["local"]])
                    guard mine == self.generation else { return }
                    if self.pendingWrites == 0 {
                        let next = MacHomeRow.rows(fromHomeInbox: data)
                        if self.rows != next { self.rows = next }
                    }
                    self.problem = nil
                } catch {
                    guard mine == self.generation else { return }
                    self.problem = Self.reason(error)
                }
                if !self.readAgain { break }
            }
        }
    }

    @ObservationIgnored private var needsRelist = false
    @ObservationIgnored private var opening = false

    private func listed(_ client: DaemonClient) async throws {
        let list = try await Self.call(client, "conversation-list", [:])
        var seqs: [String: Int] = [:]
        for summary in list["conversations"] as? [[String: Any]] ?? [] {
            if let id = summary["id"] as? String { seqs[id] = (summary["last_seq"] as? NSNumber)?.intValue ?? 0 }
        }
        lastSeq = seqs
        macChiefID = ChiefWire(identity: .standard).chiefConversation(in: list["conversations"] as? [[String: Any]] ?? [])
    }

    // MARK: The person's list state (the Mac's owner keeps it)

    /// Pin (after the person's other pins, by time as the Mac numbers them) or Unpin.
    public func setPinned(_ on: Bool, _ id: String) {
        var op: [String: Any] = ["kind": "inbox.pin", "pinned": on]
        if on { op["position"] = UInt64(Date().timeIntervalSince1970 * 1000) }
        if var list = rows, let index = list.firstIndex(where: { $0.id == id }) {
            // Shown at the end of the pinned rows (or first among the others) until the owner's rows come back.
            let row = list.remove(at: index).with(pinned: on)
            list.insert(row, at: list.firstIndex { !$0.isPinned } ?? list.endIndex)
            rows = list
        }
        write(id, cmd: "conversation-inbox-op", ["conversation": id, "op": op])
    }

    /// Mark as Unread, or clear the mark.
    public func setMarkedUnread(_ on: Bool, _ id: String) {
        guard let row = rows?.first(where: { $0.id == id }), row.markedUnread != on else { return }
        edit(id) { $0.with(markedUnread: on) }
        write(id, cmd: "conversation-inbox-op", ["conversation": id, "op": ["kind": "inbox.mark_unread", "unread": on]])
    }

    /// Mark as Read, as on the Mac: the mark goes, and the read cursor moves to the newest message.
    public func markRead(_ id: String) {
        setMarkedUnread(false, id)
        guard let client, let row = rows?.first(where: { $0.id == id }), row.unread > 0 else { return }
        pendingWrites += 1
        let mine = generation
        // task-owner: one read-cursor move (the newest seq, then the op); ends with its reply
        Task { [weak self] in
            if let self, (try? await self.listed(client)) != nil, mine == self.generation, let seq = self.lastSeq[id], seq > 0 {
                _ = try? await Self.call(client, "conversation-op", ["conversation": id, "idempotency_key": UUID().uuidString.lowercased(),
                                                                     "op": ["kind": "read_cursor.set", "seq": seq]])
            }
            guard let self, mine == self.generation else { return }
            self.pendingWrites -= 1
            if self.pendingWrites == 0 { self.refresh() }
        }
    }

    private func edit(_ id: String, _ change: (MacHomeRow) -> MacHomeRow) {
        guard var list = rows, let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index] = change(list[index])
        rows = list
    }

    /// Sends one write, then reads the rows again (the owner's answer wins over the edit shown).
    private func write(_ id: String, cmd: String, _ params: [String: Any]) {
        guard let client, let body = try? JSONSerialization.data(withJSONObject: params) else { return }
        pendingWrites += 1
        let mine = generation
        // task-owner: one list-state write; ends with its reply
        Task { [weak self] in
            // A fresh copy for the request (the dictionary itself is not Sendable).
            if let fresh = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                _ = try? await Self.call(client, cmd, fresh)
            }
            guard let self, mine == self.generation else { return }
            self.pendingWrites -= 1
            if self.pendingWrites == 0 { self.refresh() }
        }
    }

    nonisolated static func reason(_ error: any Error) -> String {
        if let error = error as? LinkError, !error.message.isEmpty { return String(error.message.prefix(80)) }
        return error.localizedDescription
    }

    /// One command's `data`, or the owner's refusal.
    static func call(_ client: DaemonClient, _ cmd: String, _ params: sending [String: Any]) async throws -> [String: Any] {
        let line = try await client.request(cmd, params: params)
        guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw LinkError(code: "bad_reply", message: "bad reply to \(cmd)")
        }
        if reply["ok"] as? Bool == false {
            let error = reply["error"]
            let text = (error as? [String: Any])?["message"] as? String ?? error as? String ?? "\(cmd) failed"
            throw LinkError(code: "refused", message: text)
        }
        return reply["data"] as? [String: Any] ?? [:]
    }
}

extension MacHomeRow {
    func with(pinned: Bool? = nil, markedUnread: Bool? = nil) -> MacHomeRow {
        MacHomeRow(id: id, kind: kind, name: name, unread: unread, activityAt: activityAt, preview: preview, chief: chief,
                   chiefState: chiefState, isPinned: pinned ?? isPinned, pinPosition: pinPosition,
                   markedUnread: markedUnread ?? self.markedUnread, isMuted: isMuted)
    }

    init(id: String, kind: Kind, name: String, unread: Int, activityAt: Date, preview: String, chief: String?,
         chiefState: ChiefState?, isPinned: Bool, pinPosition: UInt64?, markedUnread: Bool, isMuted: Bool) {
        self.id = id
        self.kind = kind
        self.name = name
        self.unread = unread
        self.activityAt = activityAt
        self.preview = preview
        self.chief = chief
        self.chiefState = chiefState
        self.isPinned = isPinned
        self.pinPosition = pinPosition
        self.markedUnread = markedUnread
        self.isMuted = isMuted
    }
}
