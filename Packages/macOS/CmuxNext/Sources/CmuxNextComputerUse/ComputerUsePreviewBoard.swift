import Foundation

/// What a chat's live preview card shows (the App draws it in the chat's page).
public nonisolated struct ComputerUsePreviewCard: Equatable, Sendable {
    /// The Computer Use session.
    public var session: String
    /// The app's name: the driver's, else the app's display name, else its window's title; "" when
    /// none is known. The card shows no name: it is in the card's accessible label only.
    public var app: String
    /// The session ended: the last frame, dimmed, with the app's icon and a check.
    public var done: Bool
    /// The newest frame, a `data:image/...` URL.
    public var frame: String
    /// The app's icon, a `data:image/png` URL: sent with the done state only, when known.
    public var icon: String?
    /// Where the agent clicked last in the window the frame shows: the card draws its cursor there.
    /// Running cards only.
    public var pointer: ComputerUsePreviewPointer?

    public init(session: String, app: String, done: Bool, frame: String, icon: String? = nil,
                pointer: ComputerUsePreviewPointer? = nil) {
        self.session = session
        self.app = app
        self.done = done
        self.frame = frame
        self.icon = icon
        self.pointer = pointer
    }
}

/// A click on a card.
public nonisolated enum ComputerUsePreviewClick: String, Sendable {
    /// Open Agent Activity on the card's session.
    case open
    /// Hide the card for its session.
    case close
}

/// The live preview cards' state (B6), with no I/O: which Computer Use sessions feed a card, the
/// chat each shows in, the frame each wants and the one it has, and which the person closed.
/// ``ComputerUseLivePreview`` feeds it a ``ComputerUseLivePreviewSource``'s pushes, loads the
/// frames it asks for and pushes each chat's card to its page.
///
/// - A card is a chat's, not a session's: one agent turn can make several sessions at once (one
///   launches the app, another clicks), and every session routed to the chat feeds its one card.
/// - A session feeds a card only when it is first seen live: one that ended before the app saw it
///   never shows.
/// - The card shows the newest frame by capture time across its sessions. It runs while any of
///   them runs; once all have ended (or gone from the source's list) or the chat's turn is over, it
///   keeps its last frame and turns done. A new act runs it again.
/// - Closed, the card's sessions stay hidden; a newer session in the same chat shows again.
/// - Off (`computerUse.livePreview`), nothing shows and nothing is kept.
/// - While a card runs and the person can see its chat, ``liveTarget(canSee:)`` names the window to
///   stream (``ComputerUseLiveCapture``); its frames come in as loaded frames, newer than any action's.
nonisolated struct ComputerUsePreviewBoard: Sendable {
    /// A frame the source named: its id and when it was captured.
    struct FrameRef: Equatable, Sendable {
        var id: String
        var at: Date
    }

    /// A loaded frame: its id, when it was captured, and its `data:` URL.
    struct Frame: Equatable, Sendable {
        var id: String
        var at: Date
        var url: String
    }

    struct Entry: Equatable, Sendable {
        var session: ComputerUsePreviewSession
        /// The chat tab the card shows in; nil until a route found one.
        var chat: String?
        /// The acpmux session tab `chat` showed when the route was made: the route holds only while
        /// the tab still shows it (`chat.select` switches a tab to another chat under the same key).
        var chatSession: String?
        /// An id named the chat (``ComputerUsePreviewRoute/Pick/exact``).
        var exact = false
        /// The newest frame the source named.
        var wanted: FrameRef?
        /// The frame the card shows.
        var frame: Frame?
        /// The window the session acted on or read last (the live capture streams it).
        var window: ComputerUsePreviewWindow?
        /// Where the session's agent clicked last, for a pixel click (an accessibility click has no point).
        var pointer: ComputerUsePreviewPointer?
        /// The agent cursor in the streamed window (``ComputerUseLiveCapture``).
        var cursor: ComputerUseAgentCursor?
        /// The session's newest click event, of any kind.
        var lastClick: UInt64?
        /// The person closed the card.
        var dismissed = false
        /// The card hid itself after it stayed done (``autoHide(chat:)``): a newer action shows it again.
        var autoHidden = false
        /// The source's list no longer has the session.
        var gone = false
        /// The chat's turn is over: the agent stopped using the app, though the driver may keep
        /// the session open until its idle timeout.
        var turnEnded = false
        /// Its chat was seen working while the card was in it: only then does an idle chat mean the
        /// turn that used the app is over (an agent outside the chat's turns never turns done here).
        var sawTurn = false

        /// The session itself ended.
        var ended: Bool { gone || !session.live }
        var done: Bool { ended || turnEnded }
        /// Closed by the person or hidden after its turn: no card, no frames, no stream.
        var hidden: Bool { dismissed || autoHidden }
    }

    /// The most sessions kept: the oldest ended ones go first.
    static let maximumEntries = 8

    private(set) var entries: [String: Entry] = [:]

    /// `computerUse.livePreview`; off drops every card.
    var enabled = true {
        didSet { if !enabled { entries.removeAll() } }
    }

    /// Takes the source's whole session list. Returns the sessions whose newest frame to ask for
    /// again: new ones, ones that acted since the last list, and ones that just ended.
    @discardableResult
    mutating func apply(sessions: [ComputerUsePreviewSession]) -> Set<String> {
        guard enabled else { return [] }
        var listed: [String: ComputerUsePreviewSession] = [:]
        for session in sessions where listed[session.id] == nil { listed[session.id] = session }
        var read: Set<String> = []
        for (id, entry) in entries where listed[id] == nil && !entry.gone {
            entries[id]?.gone = true
        }
        for session in listed.values {
            if var entry = entries[session.id] {
                let acted = entry.session.lastActionAt != session.lastActionAt || entry.session.steps != session.steps
                let ended = entry.session.live && !session.live
                entry.session = session
                entry.gone = false
                if acted {
                    entry.turnEnded = false
                    entry.autoHidden = false
                }
                entries[session.id] = entry
                if !entry.hidden, acted || ended { read.insert(session.id) }
            } else if session.live {
                entries[session.id] = Entry(session: session)
                read.insert(session.id)
            }
        }
        trim()
        return read.filter { entries[$0] != nil }
    }

    /// The source named `frame`, captured at `at`, the newest frame of `session`.
    mutating func apply(newestFrame frame: String, at: Date, session: String) {
        entries[session]?.wanted = FrameRef(id: frame, at: at)
    }

    /// `session` acted on or read `window` last.
    mutating func apply(window: ComputerUsePreviewWindow, session: String) {
        entries[session]?.window = window
    }

    /// `session`'s agent clicked at `pointer` last.
    mutating func apply(pointer: ComputerUsePreviewPointer, session: String) {
        entries[session]?.pointer = pointer
    }

    /// `session`'s agent cursor is at `cursor` in its streamed window; nil: it does not show there.
    mutating func apply(cursor: ComputerUseAgentCursor?, session: String) {
        entries[session]?.cursor = cursor
    }

    /// `session`'s agent clicked (event `click`).
    mutating func apply(click: UInt64, session: String) {
        entries[session]?.lastClick = click
    }

    /// Gives each live session without a chat its chat; an id that names a chat moves a guessed one
    /// there. A route holds only while its tab shows the chat it was made for: a tab that closed, or
    /// switched to another acpmux session, drops it, and the session is routed again at once (an
    /// ended one then shows nowhere). Each card turns done or running again with its chat's turn.
    mutating func route(chats: [ComputerUsePreviewChat]) {
        var byKey: [String: ComputerUsePreviewChat] = [:]
        for chat in chats { byKey[chat.key] = chat }
        for id in entries.keys {
            guard var entry = entries[id] else { continue }
            if let key = entry.chat, byKey[key].map({ $0.session != entry.chatSession }) ?? true {
                entry.chat = nil
                entry.chatSession = nil
                entry.exact = false
            }
            if !entry.ended, entry.chat == nil || !entry.exact,
               let pick = ComputerUsePreviewRoute.pick(for: entry.session, chats: chats),
               entry.chat == nil || (pick.exact && pick.key != entry.chat) {
                entry.chat = pick.key
                entry.chatSession = byKey[pick.key]?.session
                entry.exact = pick.exact
                entry.sawTurn = false
            }
            let chat = entry.chat.flatMap { byKey[$0] }
            if chat?.working == true { entry.sawTurn = true }
            entry.turnEnded = entry.sawTurn && chat?.turnEnded == true
            entries[id] = entry
        }
    }

    /// The chats that show a card or will once a frame loads.
    var routedChats: Set<String> {
        Set(entries.values.compactMap { $0.hidden ? nil : $0.chat })
    }

    /// A frame finished loading for `session`. One captured before the frame it has is dropped: an
    /// action's frame that loads after a live frame never takes the card back in time.
    mutating func loaded(_ frame: Frame, session: String) {
        guard let entry = entries[session], entry.frame.map({ frame.at >= $0.at }) ?? true else { return }
        entries[session]?.frame = frame
    }

    /// The window to stream live: of the running sessions whose card the person can see (by chat),
    /// the one that acted last. Nil when none runs, none named its window, or no such chat is seen.
    func liveTarget(canSee: (String) -> Bool) -> ComputerUseLiveCapture.Target? {
        guard enabled else { return nil }
        let running = entries.values.compactMap { entry -> (Entry, String, ComputerUsePreviewWindow)? in
            guard !entry.hidden, !entry.done, let chat = entry.chat, let window = entry.window else { return nil }
            return (entry, chat, window)
        }
        guard let pick = running.filter({ canSee($0.1) }).max(by: {
            ($0.0.session.lastActionAt, $0.0.session.id) < ($1.0.session.lastActionAt, $1.0.session.id)
        }) else { return nil }
        return ComputerUseLiveCapture.Target(session: pick.0.session.id, chat: pick.1, window: pick.2)
    }

    /// The chats a live stream could show in: running, not closed, with a known window. Whether the
    /// person can see them is followed only while this is not empty.
    var liveChats: Set<String> {
        Set(entries.values.compactMap { $0.hidden || $0.done || $0.window == nil ? nil : $0.chat })
    }

    /// Frame `frame` of `session` could not load (gone, or the source failed): it is not asked
    /// for again, and the card keeps the frame it has.
    mutating func failed(_ frame: String, session: String) {
        guard var entry = entries[session], entry.wanted?.id == frame else { return }
        entry.wanted = entry.frame.map { FrameRef(id: $0.id, at: $0.at) }
        entries[session] = entry
    }

    /// The person closed the card that shows `session`: every session that feeds it stays hidden.
    /// Returns those sessions.
    @discardableResult
    mutating func dismiss(session: String) -> Set<String> {
        guard let entry = entries[session] else { return [] }
        let feeding = entry.chat.map { chat in entries.values.filter { $0.chat == chat && !$0.dismissed }.map(\.session.id) } ?? []
        let closed = Set(feeding).union([session])
        for id in closed { entries[id]?.dismissed = true }
        return closed
    }

    /// Chat `chat`'s card stayed done: every session that feeds it hides until it acts again.
    /// Returns those sessions.
    @discardableResult
    mutating func autoHide(chat: String) -> Set<String> {
        let feeding = Set(entries.values.filter { $0.chat == chat && !$0.hidden }.map(\.session.id))
        for id in feeding { entries[id]?.autoHidden = true }
        return feeding
    }

    /// The card chat `chat` shows, fed by every session routed there: the newest frame by capture
    /// time, with that frame's session and app; done only once all of them are. Only once a frame
    /// has loaded. `apps` holds the apps looked up so far (``appKeys``).
    func card(for chat: String, apps: [ComputerUsePreviewApp.Key: ComputerUsePreviewApp] = [:]) -> ComputerUsePreviewCard? {
        guard enabled else { return nil }
        let feeding = entries.values.filter { $0.chat == chat && !$0.hidden }
        guard let entry = feeding.max(by: { Self.earlier($0.frame, than: $1.frame, $0.session.id, $1.session.id) }),
              let frame = entry.frame else { return nil }
        let session = entry.session
        let done = feeding.allSatisfy(\.done)
        let app = session.appKey.flatMap { apps[$0] }
        let name = [session.app, app?.name, session.windowTitle].lazy.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        let pointer = done ? nil : Self.pointer(entry)
        return ComputerUsePreviewCard(session: session.id, app: name ?? "", done: done, frame: frame.url,
                                      icon: done ? app?.icon : nil, pointer: pointer)
    }

    /// The next frame to load: the newest by capture time that a card can show, so newer than the
    /// frame its chat's card has (a session's older frame named late never loads). One load at a
    /// time, so the newest always wins. A session streamed live loads its action frames too: while the
    /// stream runs they are older than its frames and do not load, and when it stalls they still show.
    func nextLoad() -> (session: String, frame: FrameRef)? {
        guard enabled else { return nil }
        var shown: [String: Date] = [:]
        for entry in entries.values where !entry.hidden {
            guard let chat = entry.chat, let frame = entry.frame else { continue }
            shown[chat] = max(shown[chat] ?? .distantPast, frame.at)
        }
        let waiting = entries.values.compactMap { entry -> (session: String, frame: FrameRef)? in
            guard !entry.hidden, let chat = entry.chat, let wanted = entry.wanted, wanted.id != entry.frame?.id,
                  shown[chat].map({ wanted.at > $0 }) ?? true else { return nil }
            return (entry.session.id, wanted)
        }
        return waiting.max { ($0.frame.at, $0.session) < ($1.frame.at, $1.session) }
    }

    /// The sessions whose frames the board follows: live and not closed.
    var followed: Set<String> {
        Set(entries.values.filter { !$0.done && !$0.hidden }.map(\.session.id))
    }

    /// The apps the kept sessions use, to look up for their names and icons.
    var appKeys: Set<ComputerUsePreviewApp.Key> {
        Set(entries.values.compactMap(\.session.appKey))
    }

    /// The cursor a running card draws, in the window its frames show: the live agent cursor, else
    /// the last pixel click. Its click is the newest click event, so an accessibility click plays too.
    static func pointer(_ entry: Entry) -> ComputerUsePreviewPointer? {
        guard let window = entry.window else { return nil }
        let click = max(entry.lastClick ?? 0, entry.pointer?.click ?? 0)
        if let cursor = entry.cursor {
            return ComputerUsePreviewPointer(window: window, x: cursor.point.x, y: cursor.point.y, click: click,
                                             windowWidth: cursor.windowWidth)
        }
        guard let last = entry.pointer, last.window == window else { return nil }
        return ComputerUsePreviewPointer(window: window, x: last.x, y: last.y, click: click)
    }

    /// No frame before any, then by capture time, then by session id.
    private static func earlier(_ lhs: Frame?, than rhs: Frame?, _ lhsSession: String, _ rhsSession: String) -> Bool {
        guard let rhs else { return false }
        guard let lhs else { return true }
        return (lhs.at, lhsSession) < (rhs.at, rhsSession)
    }

    /// Running before ended, then by last action, then by id.
    private static func older(_ lhs: Entry, than rhs: Entry) -> Bool {
        if lhs.done != rhs.done { return lhs.done }
        if lhs.session.lastActionAt != rhs.session.lastActionAt { return lhs.session.lastActionAt < rhs.session.lastActionAt }
        return lhs.session.id < rhs.session.id
    }

    private mutating func trim() {
        guard entries.count > Self.maximumEntries else { return }
        let keep = Set(entries.values.sorted { Self.older($1, than: $0) }.prefix(Self.maximumEntries).map(\.session.id))
        entries = entries.filter { keep.contains($0.key) }
    }
}
