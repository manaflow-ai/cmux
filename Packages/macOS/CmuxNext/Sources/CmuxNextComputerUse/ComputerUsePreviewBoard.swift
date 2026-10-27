import Foundation

/// What a chat's live preview card shows (the App draws it in the chat's page).
public nonisolated struct ComputerUsePreviewCard: Equatable, Sendable {
    /// The Computer Use session.
    public var session: String
    /// The app's name: the driver's, else the app's display name, else its window's title; "" when
    /// none is known (the card then shows no title).
    public var app: String
    /// The session ended: the last frame, dimmed, with the app's icon and a check.
    public var done: Bool
    /// The newest frame, a `data:image/...` URL.
    public var frame: String
    /// The app's icon, a `data:image/png` URL: sent with the done state only, when known.
    public var icon: String?

    public init(session: String, app: String, done: Bool, frame: String, icon: String? = nil) {
        self.session = session
        self.app = app
        self.done = done
        self.frame = frame
        self.icon = icon
    }
}

/// A click on a card.
public nonisolated enum ComputerUsePreviewClick: String, Sendable {
    /// Open Agent Activity on the card's session.
    case open
    /// Hide the card for its session.
    case close
}

/// The live preview cards' state (B6), with no I/O: which Computer Use sessions have a card, the
/// chat each shows in, the frame each wants and the one it has, and which the person closed.
/// ``ComputerUseLivePreview`` feeds it a ``ComputerUseLivePreviewSource``'s pushes, loads the
/// frames it asks for and pushes each chat's card to its page.
///
/// - A session gets a card only when it is first seen live: a session that ended before the app
///   saw it never shows.
/// - Running, the card shows the newest frame; ended (or gone from the source's list), or once its
///   chat's turn is over, it keeps its last frame and turns done. A new act runs it again.
/// - Closed, the session's card stays hidden; a newer session in the same chat shows its own.
/// - Off (`computerUse.livePreview`), nothing shows and nothing is kept.
nonisolated struct ComputerUsePreviewBoard: Sendable {
    /// A loaded frame: its id and its `data:` URL.
    struct Frame: Equatable, Sendable {
        var id: String
        var url: String
    }

    struct Entry: Equatable, Sendable {
        var session: ComputerUsePreviewSession
        /// The chat tab the card shows in; nil until a route found one.
        var chat: String?
        /// An id named the chat (``ComputerUsePreviewRoute/Pick/exact``).
        var exact = false
        /// The newest frame the source named.
        var wanted: String?
        /// The frame the card shows.
        var frame: Frame?
        /// The person closed the card.
        var dismissed = false
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
                if acted { entry.turnEnded = false }
                entries[session.id] = entry
                if !entry.dismissed, acted || ended { read.insert(session.id) }
            } else if session.live {
                entries[session.id] = Entry(session: session)
                read.insert(session.id)
            }
        }
        trim()
        return read.filter { entries[$0] != nil }
    }

    /// The source named `frame` the newest frame of `session`.
    mutating func apply(newestFrame frame: String, session: String) {
        entries[session]?.wanted = frame
    }

    /// Gives each live session without a chat (or whose chat closed) its chat; an id that names a
    /// chat moves a guessed one there. An ended session whose chat closed shows nowhere. Each card
    /// turns done or running again with its chat's turn.
    mutating func route(chats: [ComputerUsePreviewChat], focused: String?) {
        var byKey: [String: ComputerUsePreviewChat] = [:]
        for chat in chats { byKey[chat.key] = chat }
        for id in entries.keys {
            guard var entry = entries[id] else { continue }
            let stale = entry.chat.map { byKey[$0] == nil } ?? true
            if entry.ended {
                if stale { entry.chat = nil }
            } else if stale || !entry.exact,
                      let pick = ComputerUsePreviewRoute.pick(for: entry.session, chats: chats, focused: focused),
                      stale || (pick.exact && pick.key != entry.chat) {
                if entry.chat != pick.key { entry.sawTurn = false }
                entry.chat = pick.key
                entry.exact = pick.exact
            } else if stale {
                entry.chat = nil
            }
            let chat = entry.chat.flatMap { byKey[$0] }
            if chat?.working == true { entry.sawTurn = true }
            entry.turnEnded = entry.sawTurn && chat?.turnEnded == true
            entries[id] = entry
        }
    }

    /// The chats that show a card or will once a frame loads.
    var routedChats: Set<String> {
        Set(entries.values.compactMap { $0.dismissed ? nil : $0.chat })
    }

    /// A frame finished loading for `session`.
    mutating func loaded(_ frame: Frame, session: String) {
        entries[session]?.frame = frame
    }

    /// Frame `frame` of `session` could not load (gone, or the source failed): it is not asked
    /// for again, and the card keeps the frame it has.
    mutating func failed(_ frame: String, session: String) {
        guard var entry = entries[session], entry.wanted == frame else { return }
        entry.wanted = entry.frame?.id
        entries[session] = entry
    }

    /// The person closed the card of `session`.
    mutating func dismiss(session: String) {
        entries[session]?.dismissed = true
    }

    /// The card chat `chat` shows: its newest running session's, else its newest ended one's;
    /// only once a frame has loaded. `apps` holds the apps looked up so far (``appKeys``).
    func card(for chat: String, apps: [ComputerUsePreviewApp.Key: ComputerUsePreviewApp] = [:]) -> ComputerUsePreviewCard? {
        guard enabled else { return nil }
        let shown = entries.values.filter { $0.chat == chat && !$0.dismissed && $0.frame != nil }
        guard let entry = shown.max(by: { Self.older($0, than: $1) }), let frame = entry.frame else { return nil }
        let session = entry.session
        let app = session.appKey.flatMap { apps[$0] }
        let name = [session.app, app?.name, session.windowTitle].lazy.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return ComputerUsePreviewCard(session: session.id, app: name ?? "", done: entry.done, frame: frame.url,
                                      icon: entry.done ? app?.icon : nil)
    }

    /// The next frame to load: of the newest session whose card can show and whose wanted frame
    /// is not the one it has. One load at a time, so the newest always wins.
    func nextLoad() -> (session: String, frame: String)? {
        let waiting = entries.values.filter { entry in
            guard enabled, !entry.dismissed, entry.chat != nil, let wanted = entry.wanted else { return false }
            return wanted != entry.frame?.id
        }
        guard let entry = waiting.max(by: { Self.older($0, than: $1) }), let wanted = entry.wanted else { return nil }
        return (entry.session.id, wanted)
    }

    /// The sessions whose frames the board follows: live and not closed.
    var followed: Set<String> {
        Set(entries.values.filter { !$0.done && !$0.dismissed }.map(\.session.id))
    }

    /// The apps the kept sessions use, to look up for their names and icons.
    var appKeys: Set<ComputerUsePreviewApp.Key> {
        Set(entries.values.compactMap(\.session.appKey))
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
