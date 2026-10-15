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
}

/// The data source of the Home sidebar (the vendored MessagesLab sidebar
/// reads it): the model from HomeStore's rows, the pins, the search text,
/// and the user's choices (select a conversation, pin, start a DM). With an
/// owner that serves `home-inbox` (`inbox`), the local conversations take
/// their kind, name, unread, pins, marks and order from the owner's rows;
/// Cloud conversations (not in those rows yet) keep this Mac's pins and marks.
@Observable @MainActor
public final class HomeSidebarSource {
    @ObservationIgnored private let store: HomePinStore
    @ObservationIgnored private let inbox: HomeInboxSource?
    @ObservationIgnored private let account: @MainActor () -> String
    @ObservationIgnored private let rows: @MainActor () -> [InboxRow]
    @ObservationIgnored private let me: @MainActor () -> ParticipantID?
    @ObservationIgnored private let contacts: @MainActor () -> [HomeContact]
    @ObservationIgnored private let chiefAvatar: @MainActor () -> HomeChiefAvatar?
    public var query = ""
    public private(set) var pins = HomePins()
    /// Conversations shown unread by the user's Mark as Unread until they open or read them.
    public private(set) var unreadMarks: Set<ConversationID> = []
    @ObservationIgnored public var onSelect: (ConversationID) -> Void = { _ in }
    @ObservationIgnored public var onStart: (HomeContact) -> Void = { _ in }
    #if DEBUG
    /// DEBUG: conversations listed besides the store's (`debug.home.sidebar_fixture`).
    @ObservationIgnored public var debugRows: [InboxRow] = []
    #endif

    public init(store: HomePinStore, inbox: HomeInboxSource? = nil, account: @escaping @MainActor () -> String,
         rows: @escaping @MainActor () -> [InboxRow],
         me: @escaping @MainActor () -> ParticipantID?, contacts: @escaping @MainActor () -> [HomeContact],
         chiefAvatar: @escaping @MainActor () -> HomeChiefAvatar? = { nil }) {
        self.store = store
        self.inbox = inbox
        self.account = account
        self.rows = rows
        self.me = me
        self.contacts = contacts
        self.chiefAvatar = chiefAvatar
    }

    /// The owner's rows (nil: the owner does not serve `home-inbox`), for observers of the list.
    public var ownerRows: [HomeInboxRequest.Row]? { inbox?.rows }

    /// The store's rows (plus DEBUG fixture rows).
    private func listed() -> [InboxRow] {
        #if DEBUG
        return debugRows.isEmpty ? rows() : rows() + debugRows
        #else
        return rows()
        #endif
    }

    public func model(now: Date = Date()) -> HomeSidebarModel { model(query: query, now: now) }

    private func model(query: String, now: Date) -> HomeSidebarModel {
        let listed = listed()
        guard let owned = inbox?.rows else {
            return HomeSidebarModel(rows: listed, pins: pins, me: me(), query: query, contacts: query.isEmpty ? [] : contacts(),
                                    unreadMarks: unreadMarks, chiefAvatar: chiefAvatar(), now: now)
        }
        let list = HomeInboxMapping(owned: owned, listed: listed, pins: pins, unreadMarks: unreadMarks)
        return HomeSidebarModel(ordered: list.rows, pinned: list.pinned, me: me(), query: query, contacts: query.isEmpty ? [] : contacts(),
                                unreadMarks: list.unreadMarks, chiefAvatar: chiefAvatar(), now: now)
    }

    func select(_ id: ConversationID) { onSelect(id) }

    func start(with contact: HomeContact) { onStart(contact) }

    /// Whether the owner's rows list `id` (its pins and marks are the owner's).
    private func isOwned(_ id: ConversationID) -> Bool {
        inbox?.rows?.contains { $0.id == id.rawValue } == true
    }

    /// Pins or unpins `id`: with the owner when it lists `id`, else for this account on this Mac.
    public func setPinned(_ on: Bool, _ id: ConversationID) {
        if let inbox, isOwned(id) { return inbox.setPinned(on, id.rawValue) }
        guard let row = listed().first(where: { $0.id == id }) else { return }
        pins.setPinned(on, row)
        store.save(pins, account: account())
    }

    /// Puts `id` at `index` of the pinned grid (a drag: a new place, or a row pinned there) and
    /// keeps the order: with the owner among its pinned rows when it lists `id`, else with this account's pins.
    public func place(_ id: ConversationID, at index: Int) {
        let shown = model(query: "", now: Date()).pinned.map(\.id)
        if let inbox, isOwned(id) {
            var order = shown.filter { $0 != id && isOwned($0) }
            order.insert(id, at: min(max(0, index), order.count))
            return inbox.place(order.map(\.rawValue))
        }
        pins.place(id, at: index, shown: shown)
        store.save(pins, account: account())
    }

    /// Marks `id` unread (Mark as Unread) or clears the mark (Mark as Read, opening it): with the
    /// owner when it lists `id`, else for this account on this Mac.
    public func setMarkedUnread(_ on: Bool, _ id: ConversationID) {
        if let inbox, isOwned(id) { return inbox.setMarkedUnread(on, id.rawValue) }
        guard unreadMarks.contains(id) != on else { return }
        if on { unreadMarks.insert(id) } else { unreadMarks.remove(id) }
        store.save(unreadMarks: unreadMarks, account: account())
    }

    /// The signed-in account changed: its own pins and unread marks.
    public func reloadPins() {
        pins = store.pins(account: account())
        unreadMarks = store.unreadMarks(account: account())
    }
}
