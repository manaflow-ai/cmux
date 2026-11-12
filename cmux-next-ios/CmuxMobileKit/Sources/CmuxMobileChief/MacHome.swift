import CmuxConversationCore
import CmuxMobileTransport
import Foundation
import Observation

/// Markdown to one plain line, as a list preview: the rows, Chief's pin
/// bubble and its VoiceOver label (F4).
///
/// Runs once per row of every Home read, so a text with nothing to strip costs one pass
/// over its bytes and no regular expression (`home_list_first_screen`,
/// cmux-next-ios/design/instant-perf.md).
func plainPreview(_ markdown: String) -> String {
    var text = markdown
    if text.utf8.contains(UInt8(ascii: "`")) {
        text = text.replacingOccurrences(of: "```[a-z]*", with: "", options: .regularExpression)
    }
    if text.utf8.contains(where: { PreviewMarkers.bytes.contains($0) }) {
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: text.unicodeScalars.lazy.filter { !PreviewMarkers.scalars.contains($0) })
        text = String(kept)
    }
    if PreviewMarkers.needsSpaceFolding(text) {
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
    return text.trimmingCharacters(in: .whitespaces)
}

/// The Markdown markers a preview drops (`[*_`#>]`), and whether a text has any run of
/// whitespace that is not already one space.
private enum PreviewMarkers {
    static let scalars: Set<Unicode.Scalar> = ["*", "_", "`", "#", ">"]
    static let bytes: Set<UInt8> = Set(scalars.map { UInt8($0.value) })

    /// False only for ASCII text whose whitespace is single spaces: then `\\s+` to one space
    /// changes nothing. Any other text (a tab, a newline, two spaces, or a non-ASCII scalar,
    /// which may be Unicode whitespace) takes the regular expression.
    static func needsSpaceFolding(_ text: String) -> Bool {
        var lastWasSpace = false
        for byte in text.utf8 {
            if byte >= 0x80 { return true }
            if byte == 0x20 {
                if lastWasSpace { return true }
                lastWasSpace = true
            } else {
                if byte == 0x09 || byte == 0x0A || byte == 0x0B || byte == 0x0C || byte == 0x0D { return true }
                lastWasSpace = false
            }
        }
        return false
    }
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
/// Codable so the phone keeps the top of the list it last read (``MacHomeRowsCache``).
public struct MacHomeRow: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case chief, direct, channel, group }
    public enum ChiefState: String, Sendable, Codable { case working, waiting, idle }

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
        if let date = WireTime.fractional.date(from: text) { return date }
        return WireTime.whole.date(from: text)
    }

    /// One pair of formatters for every row. Making the pair per row was most of a Home
    /// read: 5,000 rows took 2 s on the simulator (`home_list_first_screen`).
    /// `ISO8601DateFormatter` is safe to use from any thread.
    private enum WireTime {
        nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        nonisolated(unsafe) static let whole = ISO8601DateFormatter()
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

    /// Puts `all[i]` in place for each of `indices`, in a list built from `all` with no
    /// search or Unread filter (the pins first, as the owner orders them). False when a row
    /// is not where it would go (it changed pin, or the list is filtered): then build it again.
    mutating func patch(_ all: [MacHomeRow], at indices: [Int]) -> Bool {
        guard pinned.count + rows.count == all.count else { return false }
        for index in indices {
            guard index >= 0, index < all.count else { return false }
            let row = all[index]
            if index < pinned.count {
                guard row.isPinned, pinned[index].id == row.id else { return false }
                pinned[index] = row
            } else {
                let at = index - pinned.count
                guard !row.isPinned, rows[at].id == row.id else { return false }
                rows[at] = row
            }
        }
        return true
    }

    /// One list per change of the rows, the search or the Unread toggle: Home's
    /// body reads it on every pass. `revision` moves only when the result does,
    /// so the list animates on an integer, not on a comparison of every row.
    ///
    /// Given the rows' ``Version``, the memo keys on it and keeps no copy of the rows (a
    /// copy would make the feed's next in-place change copy every row), and a change that
    /// replaced rows in place (``MacHomeRows/Change``) patches the list instead of building
    /// it, so one row's change costs one row (`home_list_one_row_update`).
    public final class Memo {
        /// What the rows are: the feed's ``MacHomeFeed/rowsRevision`` and the hidden
        /// conversations' ``HomeHiddenConversations/revision``.
        public struct Version: Hashable, Sendable {
            public var rows: Int
            public var hidden: Int
            public init(rows: Int, hidden: Int = 0) {
                self.rows = rows
                self.hidden = hidden
            }
        }

        private var last: (rows: [MacHomeRow]?, version: Version?, query: String, unreadOnly: Bool, list: MacHomeList)?
        /// How many lists this memo built (tests).
        public private(set) var builds = 0
        /// How many changes it patched in place (tests).
        public private(set) var patches = 0
        public private(set) var revision = 0

        public init() {}

        public func list(_ rows: [MacHomeRow], query: String, unreadOnly: Bool,
                         version: Version? = nil, change: MacHomeRows.Change? = nil) -> MacHomeList {
            if var held = last, held.query == query, held.unreadOnly == unreadOnly {
                if let version, held.version == version { return held.list }
                if version == nil, held.version == nil, held.rows == rows { return held.list }
                let unfiltered = !unreadOnly && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if unfiltered, let version, let change, let before = held.version, before.hidden == version.hidden,
                   change.revision == version.rows, before.rows == change.revision - 1 {
                    // Let go of the held list first, so the patch changes its rows in place.
                    last = nil
                    if held.list.patch(rows, at: change.indices) {
                        patches += 1
                        if !change.indices.isEmpty { revision &+= 1 }
                        held.version = version
                        last = held
                        return held.list
                    }
                    // A row was not where the change puts it: built again below.
                }
            }
            let list = MacHomeList(rows, query: query, unreadOnly: unreadOnly)
            builds += 1
            if last?.list != list { revision &+= 1 }
            last = (version == nil ? rows : nil, version, query, unreadOnly, list)
            return list
        }
    }
}

/// What Home says under its rows while the Mac's own list is not in (the user, 2026-11-09:
/// "never show an empty UI for data that exists but is still loading").
public enum HomeListNote: Equatable, Sendable {
    /// Nothing to say: the Mac's list shows, or a search or a failure note speaks instead.
    case none
    /// The rows kept from an earlier read show; the Mac's list is on its way.
    case updating
    /// A Mac is chosen and nothing is kept for it: its list is on its way.
    case connecting
    /// No Mac is chosen yet, while the account lists Macs (or they are still loading).
    case loading

    /// The note for Home's state. `macsMayExist`: the account lists a Mac, or its Macs are
    /// not known yet. `failing`: the retry note shows (the list failed or the Mac is offline).
    public static func make(rows: [MacHomeRow]?, showingKept: Bool, homeMacID: String?, macsMayExist: Bool,
                            searching: Bool, failing: Bool) -> HomeListNote {
        guard !searching, !failing else { return .none }
        if rows != nil { return showingKept ? .updating : .none }
        if homeMacID != nil { return .connecting }
        return macsMayExist ? .loading : .none
    }
}

/// The bar at the top of Home while the Home Mac is not connected or its list could not be
/// read (CMUX-489). The list under it stays usable, but it is what this phone last read, not
/// the Mac's live list. The bar says so where the person looks first: at the top, not in
/// small gray text under the last row.
public struct HomeConnectionBar: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The Mac's link is down.
        case offline
        /// The link is up, but the Mac's list did not load.
        case failed
        /// A Try Again from the bar is running.
        case retrying
    }

    public let kind: Kind
    public let title: String
    /// What the list under the bar is and what happens next.
    public let detail: String

    /// The bar for Home's state, or nil while the list is live. `offline`: the Home Mac's link
    /// is neither connected nor connecting. `problem`: why the last read failed. `retrying`: a
    /// Try Again runs. `hasRows`: rows show under the bar (the last ones read).
    /// `reconnecting`: the running Try Again dials the Mac first (it was offline), else it only reads again.
    public static func make(offline: Bool, problem: String?, retrying: Bool, reconnecting: Bool = true, hasRows: Bool,
                            macName: String?) -> HomeConnectionBar? {
        let mac = macName ?? String(localized: "your Mac")
        let kind: Kind
        if retrying {
            kind = .retrying
        } else if offline {
            kind = .offline
        } else if problem != nil {
            kind = .failed
        } else {
            return nil
        }
        let title: String = switch kind {
        case .offline: String(localized: "Not connected to \(mac)")
        case .failed: String(localized: "Couldn't load Home from \(mac)")
        case .retrying: reconnecting ? String(localized: "Reconnecting to \(mac)…") : String(localized: "Loading Home from \(mac)…")
        }
        var detail: String = if hasRows {
            String(localized: "Showing the last list from this iPhone. It updates when the Mac answers.")
        } else {
            String(localized: "Its conversations show when the Mac answers.")
        }
        if kind == .failed, let problem, !problem.isEmpty { detail = "\(problem) \(detail)" }
        return HomeConnectionBar(kind: kind, title: title, detail: detail)
    }
}

/// The chosen Mac's Home list over its link: a `chief` channel of its own
/// (cmux-mobile-host scopes it to the owner's conversations with agents and to
/// the local owner's rows), read with `home-inbox` and read again (coalesced)
/// after each conversation or list-state event, as the Mac's `HomeInboxSource`
/// does. Pin, Unpin and the unread mark are the person's list state on that
/// owner (`conversation-inbox-op`), so the Mac's Home changes with them.
///
/// The list costs the first screen what a small Mac's does (``MacHomeRows``): the rows this
/// phone kept from the last read show at once (``MacHomeRowsCache``), the first window of the
/// Mac's list replaces them, the whole list follows in one read parsed off the main actor,
/// and an event reads only the rows it names. A host without windows gets whole-list reads.
@MainActor
@Observable
public final class MacHomeFeed {
    // The rows are re-read on conversation, typing and list-state events. A Chief run
    // that starts without a message or typing (`conversation-run-changed`) is not
    // forwarded over the link, so its typing shows with its next message or typing.
    public static let shared = MacHomeFeed(rowsCache: .standard, transcripts: ChiefSession.transcripts,
                                           accountID: { ChiefSources.shared.activeUserID })

    /// The owner's rows in its order; nil until the first read of this Mac. Before that read
    /// they may be the rows this phone kept from an earlier one (``isShowingKeptRows``), and
    /// until ``isComplete`` only the top of the list.
    public private(set) var rows: [MacHomeRow]?
    /// ``rows`` are the ones this phone kept from an earlier read, not yet the Mac's answer.
    public private(set) var isShowingKeptRows = false
    /// ``rows`` hold the Mac's whole list, not only its first window or the kept rows: a
    /// search or the Unread filter over them covers every conversation.
    public private(set) var isComplete = false
    /// Moves with every change of ``rows`` (Home's list memo keys on it, not on the rows).
    public private(set) var rowsRevision = 0
    /// The last change of ``rows`` when it replaced rows in place (``MacHomeRows/Change``).
    @ObservationIgnored public private(set) var lastChange: MacHomeRows.Change?
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
    /// List-state writes not answered yet: a read meanwhile could undo the edit shown.
    @ObservationIgnored private var pendingWrites = 0
    /// Rows to read once the writes are answered: each write's own row, and every row a
    /// read skipped meanwhile (``deferredAll``: a whole-list or window read was skipped).
    @ObservationIgnored private var deferredIDs: Set<String> = []
    @ObservationIgnored private var deferredAll = false
    /// Each conversation's newest seq (`conversation-list`), for Mark as Read.
    @ObservationIgnored private var lastSeq: [String: Int] = [:]
    // task-owner: the event reader of the current channel, cancelled with it
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    /// Reads waiting to run, coalesced: the first window, the whole list, or named rows.
    @ObservationIgnored private var wantsWindow = false
    @ObservationIgnored private var wantsAll = false
    @ObservationIgnored private var wantedIDs: Set<String> = []
    /// Whether this channel's host windows `home-inbox` (nil: not asked yet).
    @ObservationIgnored private var windows: Bool?
    /// Rows the first read asks for.
    @ObservationIgnored private let firstWindow: Int
    /// Each Mac's list as last read, per account (nil keeps nothing: tests).
    @ObservationIgnored private let rowsCache: MacHomeRowsCache?
    /// Each opened conversation's newest messages, per account, Mac and conversation (nil keeps nothing).
    @ObservationIgnored private let transcripts: ConversationTranscriptCache?
    /// The signed-in account, the first part of every kept key (nil: nothing is kept or shown).
    @ObservationIgnored private let accountID: @MainActor () -> String?
    /// Conversations shown from their kept messages while their channel opens, by id
    /// (``keptSession(for:)``); ``session(for:)`` turns one live.
    @ObservationIgnored private var keptSessions: [String: ChiefSession] = [:]

    public init(rowsCache: MacHomeRowsCache? = nil, transcripts: ConversationTranscriptCache? = nil,
                accountID: @escaping @MainActor () -> String? = { nil },
                firstWindow: Int = MacHomeRows.firstWindow) {
        self.rowsCache = rowsCache
        self.transcripts = transcripts
        self.accountID = accountID
        self.firstWindow = max(1, firstWindow)
    }

    /// Every change of ``rows`` goes through here (or ``applyRows(_:asked:)``'s in-place one).
    private func setRows(_ next: [MacHomeRow]?, complete: Bool) {
        isComplete = next != nil && complete
        guard next != rows else { return }
        rows = next
        rowsRevision &+= 1
        lastChange = nil
    }

    #if DEBUG
    /// The list scroll rig (verify/listperf/): `count` rows shaped like a busy Mac's Home
    /// (four pinned, some Chiefs working, long Markdown previews), with no link.
    public func seedStressRows(count: Int, macID: String) {
        let stamp = ISO8601DateFormatter()
        let kinds = ["chief", "direct", "channel", "group"]
        setRows((0..<count).compactMap { (index: Int) -> MacHomeRow? in
            let isChief = index % 6 == 0
            var wire: [String: Any] = [:]
            wire["id"] = "stress-\(index)"
            wire["kind"] = kinds[index % kinds.count]
            wire["name"] = "Conversation \(index)"
            wire["unread"] = index % 3 == 0 ? index % 5 + 1 : 0
            wire["activity_at"] = stamp.string(from: Date().addingTimeInterval(-Double(index) * 900))
            wire["preview"] = "**Done (#\(index)).** The dialer now retries with `backoff`, capped at 30 s. [Details](https://cmux.com) and 24 tests pass."
            if isChief {
                wire["chief"] = "chief-\(index)"
                wire["chief_state"] = index % 12 == 0 ? "working" : "idle"
            }
            wire["pinned"] = index < 4
            wire["pin_position"] = index
            return MacHomeRow(wire: wire)
        }, complete: true)
        self.macID = macID
    }
    #endif

    /// The Mac Chief's own conversation on this Mac (the oldest with the owner and `agent_mux`,
    /// as the Mac's Home picks it), from the owner's list: its row is the Mac Chief.
    public private(set) var macChiefID: String?

    /// The Home list of the Mac behind `link` (a new link, or another Mac):
    /// opens its own `chief` channel and reads the list. Another Mac's rows
    /// are dropped at once, so they never show under this Mac (its own kept
    /// rows show instead); conversations opened on the last link close (their
    /// channels were on it).
    public func connect(link: any MacLink, macID: String?) async {
        if macID != self.macID {
            macChiefID = nil
            lastSeq = [:]
            self.macID = macID
            showKeptRows()
        }
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
            // The first screen, then the rest of the list behind it.
            refresh(relist: false, read: .window)
        } catch {
            await opened?.close()
            guard mine == generation else { return }
            problem = Self.reason(error)
            readAnswered()
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
            let session: ChiefSession
            if let kept = keptSessions.removeValue(forKey: route.conversationID) {
                // The screen already shows this session's kept messages: it goes live in place.
                kept.use(backend, identity: identity)
                kept.unavailableTitle = nil
                kept.status = nil
                session = kept
            } else {
                session = ChiefSession(backend: backend, identity: identity, outbox: ChiefOutbox(file: nil),
                                       transcripts: transcripts, transcriptKey: transcriptKey(route.conversationID))
            }
            session.macID = macID
            sessions[route.conversationID] = session
            return session
        } catch {
            await client.close()
            throw error
        }
    }

    /// The kept transcript's key of a conversation of this Mac's list: per account, Mac and
    /// conversation, never the Mac Chief's own (`mac:<id>`).
    func transcriptKey(_ conversationID: String) -> String? {
        guard transcripts != nil, let macID, let account = accountID() else { return nil }
        return "mac-home:\(account):\(macID):\(conversationID)"
    }

    /// The conversation as this phone last saw it, shown while its channel opens
    /// (``session(for:)`` waits on the Mac's list): a session on no backend whose store shows
    /// the kept messages (in this turn when read this run, else once read off the main thread).
    /// The open session when there is one; nil when nothing can be kept (no account or Mac).
    /// Its screen shows it only once it has a message (``ChiefSession/lastMessage``).
    public func keptSession(for route: MacConversationRoute) -> ChiefSession? {
        if let session = sessions[route.conversationID] ?? keptSessions[route.conversationID] { return session }
        guard let transcripts, let key = transcriptKey(route.conversationID) else { return nil }
        let identity = ChiefIdentity(chiefID: route.chief ?? "agent_unknown", title: route.title, avatar: homeInitials(route.title))
        let session = ChiefSession(backend: ChiefOfflineBackend(reason: Self.keptReason), identity: identity,
                                   outbox: ChiefOutbox(file: nil), transcripts: transcripts, transcriptKey: key)
        session.unavailableTitle = Self.keptTitle
        session.status = Self.keptReason
        session.macID = macID
        keptSessions[route.conversationID] = session
        return session
    }

    /// The bar over a conversation shown from what the phone kept while its channel opens.
    static var keptTitle: String { String(localized: "Connecting to your Mac…") }
    static var keptReason: String { String(localized: "Showing the last messages. New ones load when it connects.") }

    /// Bumped each time the opened conversations close (a new link or another Mac):
    /// a conversation's screen asks for its session again.
    public private(set) var sessionEpoch = 0

    private func closeSessions() {
        // Kept sessions were for the last link's Mac (they never had a channel).
        keptSessions = [:]
        guard !sessions.isEmpty else { return }
        for session in sessions.values { session.backend.close() }
        sessions = [:]
        sessionEpoch += 1
    }

    /// Chief on `macID` is not reachable. Its list stays (it is read on its
    /// own channel, as the Mac keeps its list while the owner reconnects);
    /// another Mac's list goes at once, so it never shows under this Mac (the
    /// rows this phone kept from that Mac show instead).
    public func forget(unless macID: String?) {
        guard macID != self.macID else { return }
        generation += 1
        problem = nil
        macChiefID = nil
        lastSeq = [:]
        closeSessions()
        self.macID = macID
        showKeptRows()
        link = nil
        readAnswered()
        let old = detach()
        Task { await old?.close() }
    }

    /// Home shows `macID`'s list before any channel to it opened (a launch): the rows this
    /// phone kept from that Mac, if no other Mac's list shows now. Does nothing once rows show.
    public func showKeptRows(of macID: String) {
        guard rows == nil, self.macID == nil || self.macID == macID else { return }
        self.macID = macID
        showKeptRows()
    }

    /// The rows kept for this account and ``macID`` become ``rows`` (from memory in this turn,
    /// else read off the main thread), until the Mac's own rows replace them. Nothing kept:
    /// nil, so Home says it is connecting.
    private func showKeptRows() {
        setRows(nil, complete: false)
        isShowingKeptRows = false
        guard let rowsCache, let key = rowsKey() else { return }
        if let held = rowsCache.cached(key) {
            setRows(held, complete: false)
            isShowingKeptRows = true
            return
        }
        let macID = macID
        // task-owner: one disk read of the kept rows; ends with it, and its rows land only if nothing newer did
        Task { [weak self] in
            guard let kept = await rowsCache.load(key), let self,
                  self.macID == macID, self.rows == nil, self.rowsKey() == key else { return }
            self.setRows(kept, complete: false)
            self.isShowingKeptRows = true
        }
    }

    private func rowsKey() -> String? {
        guard let macID, let account = accountID() else { return nil }
        return MacHomeRowsCache.key(account: account, macID: macID)
    }

    /// Sign-out: no row, opened conversation or kept list of this account stays, in memory or on disk.
    public func discardForSignOut() {
        generation += 1
        setRows(nil, complete: false)
        isShowingKeptRows = false
        problem = nil
        macChiefID = nil
        lastSeq = [:]
        closeSessions()
        keptSessions = [:]
        macID = nil
        link = nil
        let old = detach()
        Task { await old?.close() }
        rowsCache?.removeAll()
    }

    /// Ends the current channel's state now (a later connect never meets it) and hands back its client to close.
    private func detach() -> DaemonClient? {
        eventTask?.cancel()
        eventTask = nil
        let old = client
        client = nil
        reading = false
        needsRelist = false
        wantsWindow = false
        wantsAll = false
        wantedIDs = []
        windows = nil
        pendingWrites = 0
        deferredIDs = []
        deferredAll = false
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
        // The event's own row, where it names one; missed events read the whole list.
        if event != "overflow", let conversation = object["conversation"] as? String {
            refresh(relist: summaryChanged, read: .ids([conversation]))
        } else {
            refresh(relist: true, read: .all)
        }
    }

    /// Reads the rows: one read at a time, and a request during a read runs one more after it.
    public func refresh() { refresh(relist: false, read: .all) }

    /// ``refresh()``, returning once the next read (or the channel open it needs)
    /// has answered, so a Retry shows its spinner for as long as the load and no
    /// longer. It returns at once with nothing to read from (no channel, no link),
    /// on cancellation, and after `cap` (a channel that goes quiet without closing
    /// never answers; Retry must come back to be tapped again).
    public func reload(cap: Duration = .seconds(15)) async {
        refresh(relist: false, read: .all)
        guard client != nil || opening else { return }
        readWaiterCount += 1
        let id = readWaiterCount
        // task-owner: the cap of one reload; ends at the cap or with the reload's own end
        let capTask = Task { [weak self] in
            try? await ContinuousClock().sleep(for: cap)
            self?.endReadWait(id)
        }
        defer { capTask.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { readWaiters[id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.endReadWait(id) }
        }
    }

    /// Reloads waiting for the next read's answer, by id.
    @ObservationIgnored private var readWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var readWaiterCount = 0

    private func endReadWait(_ id: Int) {
        readWaiters.removeValue(forKey: id)?.resume()
    }

    /// A read or an open answered (either way): every waiting reload returns.
    private func readAnswered() {
        let waiting = readWaiters
        readWaiters = [:]
        for waiter in waiting.values { waiter.resume() }
    }

    /// What a read asks for.
    private enum Read {
        /// The first screen (the whole list follows).
        case window
        /// The whole list.
        case all
        /// The rows of these conversations, where they now stand.
        case ids(Set<String>)
    }

    private var hasWork: Bool { needsRelist || wantsWindow || wantsAll || !wantedIDs.isEmpty }

    private func refresh(relist: Bool, read: Read) {
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
        switch read {
        case .window: wantsWindow = true
        case .all: wantsAll = true
        case .ids(let ids): wantedIDs.formUnion(ids)
        }
        if reading { return }
        reading = true
        let mine = generation
        // task-owner: the waiting home-inbox reads, one at a time, until none waits; ends with the last reply
        Task { [weak self] in
            defer { if let self, mine == self.generation { self.reading = false } }
            while let self, mine == self.generation, self.hasWork {
                let relist = self.needsRelist
                self.needsRelist = false
                do {
                    if relist { try await self.listed(client) }
                    try await self.readNext(client, mine)
                    guard mine == self.generation else { return }
                    self.problem = nil
                } catch {
                    guard mine == self.generation else { return }
                    self.problem = Self.reason(error)
                    // The next event or Retry reads again.
                    self.wantsWindow = false
                    self.wantsAll = false
                    self.wantedIDs = []
                }
                self.readAnswered()
            }
        }
    }

    /// One `home-inbox` read of the work waiting: the first window, else the whole list,
    /// else the rows events named.
    private func readNext(_ client: DaemonClient, _ mine: Int) async throws {
        if wantsWindow, windows != false {
            wantsWindow = false
            do {
                let reply = try await MacHomeReply.read(client, ["owners": ["local"], "limit": firstWindow])
                guard mine == generation else { return }
                if case .window(_, _, let total) = reply {
                    windows = true
                    // The rest of the list follows unless the window held it all.
                    wantsAll = wantsAll || total > firstWindow
                } else {
                    // A host that ignored the window answered every row.
                    windows = false
                }
                applyRows(reply, asked: [])
            } catch let error as LinkError where error.code == "refused" {
                // A host without windows refuses the params: the whole list, as before.
                guard mine == generation else { return }
                windows = false
                wantsAll = true
            }
            return
        }
        wantsWindow = false
        if wantsAll || windows != true || wantedIDs.count > MacHomeRows.idsLimit {
            wantsAll = false
            wantedIDs = []
            // Below the first window's priority: it never slows the first screen down.
            let reply = try await MacHomeReply.read(client, ["owners": ["local"]], priority: MacHomeReply.wholeListPriority)
            guard mine == generation else { return }
            applyRows(reply, asked: [])
            return
        }
        guard !wantedIDs.isEmpty else { return }
        let ids = wantedIDs
        wantedIDs = []
        let reply = try await MacHomeReply.read(client, ["owners": ["local"], "ids": ids.sorted()])
        guard mine == generation else { return }
        // The rows no longer add up to the owner's list (a change this phone missed): read it whole.
        if !applyRows(reply, asked: ids) { wantsAll = true }
    }

    /// Shows a reply's rows; false when the rows no longer agree with the owner's count.
    @discardableResult
    private func applyRows(_ reply: MacHomeReply, asked: Set<String>) -> Bool {
        // A list-state write is on its way: what this read carried is read again once the
        // writes are answered (``refreshDeferred()``), never dropped.
        guard pendingWrites == 0 else {
            if case .named = reply { deferredIDs.formUnion(asked) } else { deferredAll = true }
            return true
        }
        switch reply {
        case .all(let all):
            setRows(all, complete: true)
        case .window(let first, let offset, let total):
            if offset == 0, first.count >= total {
                // The window is the whole list: it replaces every earlier row (one the owner
                // dropped while the phone was away never comes back from the kept rows).
                setRows(first, complete: true)
            } else {
                // The first screen now; rows below it (kept, or from the last channel) stay
                // until the whole list, read next, replaces them.
                let shown = Set(first.map(\.id))
                let below = (rows ?? []).filter { !shown.contains($0.id) }
                setRows(first + below, complete: false)
            }
        case .named(let found, let total, let order):
            guard rows != nil else { return false }
            let inPlace = MacHomeRows.apply(found, asked: asked, complete: isComplete, to: &rows!)
            if inPlace?.isEmpty != true {
                rowsRevision &+= 1
                lastChange = inPlace.map { MacHomeRows.Change(revision: rowsRevision, indices: $0) }
            }
            if isComplete, rows?.count != total { return false }
            // A row placed by its index is right only if every other row is where the owner
            // has it: two moves whose reads overlapped can place one against stale neighbours.
            // The owner's order digest settles it; a mismatch reads the whole list.
            if inPlace == nil, isComplete, let order, MacHomeRows.orderDigest(rows ?? []) != order { return false }
        }
        isShowingKeptRows = false
        // The top of the Mac's list, kept for the next launch.
        if let rowsCache, let key = rowsKey(), let rows, isComplete || rows.count >= rowsCache.rowLimit {
            rowsCache.save(key, rows: rows)
        }
        return true
    }

    @ObservationIgnored private var needsRelist = false
    @ObservationIgnored private var opening = false

    private func listed(_ client: DaemonClient) async throws {
        // The owner's whole list of conversations, parsed off the main actor.
        let line = try await client.request("conversation-list", params: [:])
        let (seqs, chief) = try await Task.detached(priority: MacHomeReply.wholeListPriority) { () throws -> ([String: Int], String?) in
            let list = try Self.data(line, "conversation-list")
            let summaries = list["conversations"] as? [[String: Any]] ?? []
            var seqs: [String: Int] = [:]
            for summary in summaries {
                if let id = summary["id"] as? String { seqs[id] = (summary["last_seq"] as? NSNumber)?.intValue ?? 0 }
            }
            return (seqs, ChiefWire(identity: .standard).chiefConversation(in: summaries))
        }.value
        lastSeq = seqs
        macChiefID = chief
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
            setRows(list, complete: isComplete)
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
        deferredIDs.insert(id)
        let mine = generation
        // task-owner: one read-cursor move (the newest seq, then the op); ends with its reply
        Task { [weak self] in
            if let self, (try? await self.listed(client)) != nil, mine == self.generation, let seq = self.lastSeq[id], seq > 0 {
                _ = try? await Self.call(client, "conversation-op", ["conversation": id, "idempotency_key": UUID().uuidString.lowercased(),
                                                                     "op": ["kind": "read_cursor.set", "seq": seq]])
            }
            guard let self, mine == self.generation else { return }
            self.pendingWrites -= 1
            if self.pendingWrites == 0 { self.refreshDeferred() }
        }
    }

    private func edit(_ id: String, _ change: (MacHomeRow) -> MacHomeRow) {
        guard var list = rows, let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index] = change(list[index])
        setRows(list, complete: isComplete)
    }

    /// Sends one write, then reads its row again (the owner's answer wins over the edit shown).
    private func write(_ id: String, cmd: String, _ params: [String: Any]) {
        guard let client, let body = try? JSONSerialization.data(withJSONObject: params) else { return }
        pendingWrites += 1
        deferredIDs.insert(id)
        let mine = generation
        // task-owner: one list-state write; ends with its reply
        Task { [weak self] in
            // A fresh copy for the request (the dictionary itself is not Sendable).
            if let fresh = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                _ = try? await Self.call(client, cmd, fresh)
            }
            guard let self, mine == self.generation else { return }
            self.pendingWrites -= 1
            if self.pendingWrites == 0 { self.refreshDeferred() }
        }
    }

    /// The writes are answered: every written row and every row a read skipped meanwhile
    /// (or the whole list, when a whole-list read was skipped) is read now.
    private func refreshDeferred() {
        let ids = deferredIDs, all = deferredAll
        deferredIDs = []
        deferredAll = false
        if all || ids.isEmpty {
            refresh(relist: false, read: .all)
        } else {
            refresh(relist: false, read: .ids(ids))
        }
    }

    nonisolated static func reason(_ error: any Error) -> String {
        if let error = error as? LinkError, !error.message.isEmpty { return String(error.message.prefix(80)) }
        return error.localizedDescription
    }

    /// One command's `data`, or the owner's refusal.
    static func call(_ client: DaemonClient, _ cmd: String, _ params: sending [String: Any]) async throws -> [String: Any] {
        let line = try await client.request(cmd, params: params)
        return try data(line, cmd)
    }

    /// A reply line's `data`, or the owner's refusal.
    nonisolated static func data(_ line: Data, _ cmd: String) throws -> [String: Any] {
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
