public import CmuxHomeCore
public import CmuxNextDaemon
public import CmuxNextHome
public import Foundation
public import Observation

/// Pins kept on this Mac per account (`cmux.home.pins.<account>` in the
/// app's defaults), for the conversations the local owner's `home-inbox` does
/// not list (Cloud ones, until it lists them) and for an owner without
/// `home-inbox-v1`. The owner keeps the pins and marks of the rows it lists
/// (`conversation-inbox-op`), so both Home views show the same ones.
@MainActor
public final class HomePinStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func pins(account: String) -> HomePins {
        guard let data = defaults.data(forKey: Self.key(account)), let pins = try? JSONDecoder().decode(HomePins.self, from: data) else {
            return HomePins()
        }
        return pins
    }

    func save(_ pins: HomePins, account: String) {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        defaults.set(data, forKey: Self.key(account))
    }

    static func key(_ account: String) -> String { "cmux.home.pins.\(account)" }

    /// The conversations the user marked unread (Mark as Unread), per account
    /// (`cmux.home.unreadMarks.<account>`). The owner keeps unread as a read cursor that only
    /// moves forward and the daemon's proxy refuses `inbox.mark_unread`, so the mark lives here
    /// beside the pins until the proxy forwards it.
    func unreadMarks(account: String) -> Set<ConversationID> {
        guard let data = defaults.data(forKey: Self.marksKey(account)),
              let marks = try? JSONDecoder().decode(Set<ConversationID>.self, from: data) else { return [] }
        return marks
    }

    func save(unreadMarks: Set<ConversationID>, account: String) {
        guard let data = try? JSONEncoder().encode(unreadMarks) else { return }
        defaults.set(data, forKey: Self.marksKey(account))
    }

    static func marksKey(_ account: String) -> String { "cmux.home.unreadMarks.\(account)" }

    /// The conversations the user deleted from the list (Delete Conversation…, a swipe, `cmux home hide`),
    /// per account (`cmux.home.hidden.<account>`), each with its newest message then. As in Messages'
    /// Recently Deleted the conversation still exists: a newer message lists it again, and
    /// Show Hidden Conversations lists them all again.
    func hidden(account: String) -> [ConversationID: Seq] {
        guard let data = defaults.data(forKey: Self.hiddenKey(account)),
              let hidden = try? JSONDecoder().decode([ConversationID: Seq].self, from: data) else { return [:] }
        return hidden
    }

    func save(hidden: [ConversationID: Seq], account: String) {
        guard let data = try? JSONEncoder().encode(hidden) else { return }
        defaults.set(data, forKey: Self.hiddenKey(account))
    }

    static func hiddenKey(_ account: String) -> String { "cmux.home.hidden.\(account)" }
}

/// The data source of the Home sidebar (the vendored MessagesLab sidebar
/// reads it): the model from HomeStore's rows, the pins, the search text,
/// and the user's choices (select a conversation, pin, start a DM). With an
/// owner that serves `home-inbox` (`inboxes`: the Chief home's local rows and
/// the build daemon's Cloud rows), the conversations take their kind, name,
/// unread, pins, marks, mute and order from the owners' rows; conversations no
/// owner lists keep this Mac's pins and marks.
@Observable @MainActor
public final class HomeSidebarSource {
    @ObservationIgnored private let store: HomePinStore
    @ObservationIgnored private let inboxes: [HomeInboxSource]
    @ObservationIgnored private let account: @MainActor () -> String
    @ObservationIgnored private let rows: @MainActor () -> [InboxRow]
    @ObservationIgnored private let me: @MainActor () -> ParticipantID?
    @ObservationIgnored private let contacts: @MainActor () -> [HomeContact]
    /// Each local Chief's own avatar by participant id (`HomeChiefAvatars`), for its row alone.
    @ObservationIgnored private let chiefAvatars: @MainActor () -> [String: HomeChiefAvatar]
    /// The avatar a Chief that sets none draws (the bundled cat).
    @ObservationIgnored private let defaultChiefAvatar: @MainActor () -> HomeChiefAvatar?
    /// Each local Chief's engine by participant id (`HomeChiefHarnesses`), for the rows' badges.
    @ObservationIgnored private let chiefHarnesses: @MainActor () -> [String: String]
    /// The main Chief and where each Chief runs (``HomeChiefRoster``).
    @ObservationIgnored private let chiefRoster: @MainActor () -> HomeChiefRoster
    /// Each Chief's own name by its conversation (the user renamed it), over the title its row has.
    @ObservationIgnored private let chiefNames: @MainActor () -> [ConversationID: String]
    public var query = ""
    public private(set) var pins = HomePins()
    /// Conversations shown unread by the user's Mark as Unread until they open or read them.
    public private(set) var unreadMarks: Set<ConversationID> = []
    /// Conversations deleted from the list, with their newest message then (``HomePinStore/hidden(account:)``).
    public private(set) var hidden: [ConversationID: Seq] = [:]
    @ObservationIgnored public var onSelect: (ConversationID) -> Void = { _ in }
    @ObservationIgnored public var onStart: (HomeContact) -> Void = { _ in }
    /// This Mac's marks changed here (a Mark as Unread or Read of a row no owner lists): other
    /// sources over the same account read them again (``reloadMarks()``).
    @ObservationIgnored public var onMarksChanged: () -> Void = {}
    #if DEBUG || CMUX_BENCH_HOOKS
    /// DEBUG: conversations listed besides the store's (`debug.home.sidebar_fixture`).
    @ObservationIgnored public var debugRows: [InboxRow] = []
    /// DEBUG: team members listed besides the directory's (`debug.home.sidebar_fixture` `team`).
    @ObservationIgnored public var debugTeam: [HomeContact] = []
    #endif

    public init(store: HomePinStore, inboxes: [HomeInboxSource] = [], account: @escaping @MainActor () -> String,
         rows: @escaping @MainActor () -> [InboxRow],
         me: @escaping @MainActor () -> ParticipantID?, contacts: @escaping @MainActor () -> [HomeContact],
         chiefAvatars: @escaping @MainActor () -> [String: HomeChiefAvatar] = { [:] },
         defaultChiefAvatar: @escaping @MainActor () -> HomeChiefAvatar? = { nil },
         chiefHarnesses: @escaping @MainActor () -> [String: String] = { [:] },
         chiefRoster: @escaping @MainActor () -> HomeChiefRoster = { HomeChiefRoster() },
         chiefNames: @escaping @MainActor () -> [ConversationID: String] = { [:] }) {
        self.store = store
        self.inboxes = inboxes
        self.account = account
        self.rows = rows
        self.me = me
        self.contacts = contacts
        self.chiefAvatars = chiefAvatars
        self.defaultChiefAvatar = defaultChiefAvatar
        self.chiefHarnesses = chiefHarnesses
        self.chiefRoster = chiefRoster
        self.chiefNames = chiefNames
    }

    /// The owners' replies (nil: that owner does not serve `home-inbox`), for observers of the list.
    public var ownerRows: [HomeInboxRequest.Response?] { inboxes.map(\.reply) }

    /// What the list shows now beyond the conversations, for the next launch's first frame
    /// (`HomeSidebarLaunchCache`). `archivedChiefs` is the directory's.
    public func launchSnapshot(archivedChiefs: Set<String>) -> HomeSidebarLaunchSnapshot {
        var replies: [String: HomeInboxRequest.Response] = [:]
        for inbox in inboxes { if let reply = inbox.reply { replies[HomeSidebarLaunchSnapshot.key(inbox)] = reply } }
        return HomeSidebarLaunchSnapshot(account: account(), replies: replies, chiefAvatars: chiefAvatars(),
                                         chiefHarnesses: chiefHarnesses(), archivedChiefs: archivedChiefs, roster: chiefRoster())
    }

    /// The store's rows (plus DEBUG fixture rows).
    private func listed() -> [InboxRow] {
        #if DEBUG
        return debugRows.isEmpty ? rows() : rows() + debugRows
        #else
        return rows()
        #endif
    }

    public func model(now: Date = Date()) -> HomeSidebarModel { model(query: query, now: now) }

    /// The people the list offers (plus DEBUG fixture teammates).
    private func people() -> [HomeContact] {
        #if DEBUG
        return debugTeam.isEmpty ? contacts() : debugTeam + contacts()
        #else
        return contacts()
        #endif
    }

    /// Whether `row` stays listed: not deleted, or a message came after the delete.
    private func shows(_ row: InboxRow) -> Bool {
        guard let seq = hidden[row.id] else { return true }
        return row.summary.lastSeq > seq
    }

    private func model(query: String, now: Date) -> HomeSidebarModel {
        let listed = listed().filter(shows)
        let replies = inboxes.compactMap(\.reply)
        guard !replies.isEmpty else {
            return HomeSidebarModel(rows: listed, pins: pins, me: me(), query: query, contacts: people(),
                                    unreadMarks: unreadMarks, chiefAvatars: chiefAvatars(), defaultChiefAvatar: defaultChiefAvatar(),
                                    chiefHarnesses: chiefHarnesses(), chiefRoster: chiefRoster(), chiefNames: chiefNames(), now: now)
        }
        let owned = HomeInboxMapping.ordered(replies.map(\.rows))
        let list = HomeInboxMapping(owned: owned, listed: listed, pins: pins, unreadMarks: unreadMarks)
        var model = HomeSidebarModel(ordered: list.rows.filter(shows), pinned: list.pinned, me: me(), query: query, contacts: people(),
                                     unreadMarks: list.unreadMarks, chiefAvatars: chiefAvatars(), defaultChiefAvatar: defaultChiefAvatar(),
                                     chiefHarnesses: chiefHarnesses(), chiefRoster: chiefRoster(), chiefNames: chiefNames(), now: now)
        model.cloudState = replies.compactMap(\.cloud).first { $0 != "not_asked" }
        return model
    }

    func select(_ id: ConversationID) { onSelect(id) }

    func start(with contact: HomeContact) { onStart(contact) }

    /// The owner whose rows list `id` (its pins and marks are that owner's).
    private func owner(of id: ConversationID) -> HomeInboxSource? {
        inboxes.first { $0.rows?.contains { $0.id == id.rawValue } == true }
    }

    /// Whether `id` shows in the pinned grid.
    public func isPinned(_ id: ConversationID) -> Bool {
        model(query: "", now: Date()).pinned.contains { $0.id == id }
    }

    /// Pins or unpins `id`: with the owner when it lists `id`, else for this account on this Mac.
    public func setPinned(_ on: Bool, _ id: ConversationID) {
        if let inbox = owner(of: id) { return inbox.setPinned(on, id.rawValue) }
        guard let row = listed().first(where: { $0.id == id }) else { return }
        // This Mac's pins as stored now: the one-time move (HomePinMigration) may have taken some since the last read.
        pins = store.pins(account: account())
        pins.setPinned(on, row)
        store.save(pins, account: account())
    }

    /// Puts `id` at `index` of the pinned grid (a drag: a new place, or a row pinned there) and
    /// keeps the order: with the owner among its pinned rows when it lists `id`, else with this account's pins.
    public func place(_ id: ConversationID, at index: Int) {
        let shown = model(query: "", now: Date()).pinned.map(\.id)
        if owner(of: id) != nil {
            // The whole grid in its new order gets positions, each pin with its own owner, so pins of both owners keep that order.
            var order = shown.filter { $0 != id && owner(of: $0) != nil }
            order.insert(id, at: min(max(0, index), order.count))
            let base = HomeInboxSource.now()
            for inbox in inboxes {
                let mine = order.enumerated().filter { owner(of: $0.element) === inbox }.map { (id: $0.element.rawValue, position: base + UInt64($0.offset)) }
                if !mine.isEmpty { inbox.place(mine) }
            }
            return
        }
        // Only rows no owner lists are this Mac's to order: an owner's pin kept here would move to it again.
        var order = shown.filter { $0 != id }
        order.insert(id, at: min(max(0, index), order.count))
        let mine = order.filter { owner(of: $0) == nil }
        pins = store.pins(account: account())
        pins.place(id, at: mine.firstIndex(of: id) ?? mine.count, shown: mine)
        store.save(pins, account: account())
    }

    /// Marks `id` unread (Mark as Unread) or clears the mark (Mark as Read, opening it): with the
    /// owner when it lists `id`, else for this account on this Mac.
    public func setMarkedUnread(_ on: Bool, _ id: ConversationID) {
        if let inbox = owner(of: id) { return inbox.setMarkedUnread(on, id.rawValue) }
        guard unreadMarks.contains(id) != on else { return }
        if on { unreadMarks.insert(id) } else { unreadMarks.remove(id) }
        store.save(unreadMarks: unreadMarks, account: account())
        onMarksChanged()
    }

    /// The conversations the list dots, unfiltered by the search (``HomeSidebarModel/unreadConversations``).
    public var unreadConversations: [ConversationID] { model(query: "", now: Date()).unreadConversations }

    /// Reads this account's marks again (another source changed them).
    public func reloadMarks() {
        let marks = store.unreadMarks(account: account())
        if marks != unreadMarks { unreadMarks = marks }
    }

    /// Hide Alerts or Show Alerts for `id`, with the owner that lists it (Cloud conversations only).
    public func setMuted(_ on: Bool, _ id: ConversationID) {
        owner(of: id)?.setMuted(on, id.rawValue)
    }

    /// Whether `id` can be muted (a Cloud DM or group listed by its owner).
    public func canMute(_ id: ConversationID) -> Bool { owner(of: id)?.canMute(id.rawValue) == true }

    /// Whether `id`'s alerts are hidden, as its owner lists it (or this Mac's last Hide Alerts).
    public func isMuted(_ id: ConversationID) -> Bool {
        owner(of: id)?.rows?.first { $0.id == id.rawValue }?.muted ?? false
    }

    /// Deletes `id` from the list (it is hidden until a newer message or Show Hidden Conversations).
    /// False when no listed conversation is `id`.
    @discardableResult
    public func hide(_ id: ConversationID) -> Bool {
        guard let row = listed().first(where: { $0.id == id }) else { return false }
        hidden = store.hidden(account: account())
        hidden[id] = row.summary.lastSeq
        store.save(hidden: hidden, account: account())
        return true
    }

    /// Lists every deleted conversation again; returns how many were hidden.
    @discardableResult
    public func unhideAll() -> Int {
        let count = store.hidden(account: account()).count
        hidden = [:]
        store.save(hidden: [:], account: account())
        return count
    }

    /// The signed-in account changed: its own pins, unread marks and deleted conversations.
    public func reloadPins() {
        pins = store.pins(account: account())
        unreadMarks = store.unreadMarks(account: account())
        hidden = store.hidden(account: account())
    }
}
