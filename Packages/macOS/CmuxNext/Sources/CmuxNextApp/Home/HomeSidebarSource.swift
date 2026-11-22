import CmuxHomeCore
import CmuxNextHome
import Foundation
import Observation

/// Pins kept on this Mac per account (`cmux.home.pins.<account>` in the
/// app's defaults): the daemon's cloud proxy refuses `inbox.pin` and the
/// local owner refuses pins, so the owner cannot hold them yet. When the
/// proxy forwards `inbox.pin`, these become the owner's pins.
@MainActor
final class HomePinStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
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
/// and the user's choices (select a conversation, pin, start a DM).
@Observable @MainActor
final class HomeSidebarSource {
    @ObservationIgnored private let store: HomePinStore
    @ObservationIgnored private let account: @MainActor () -> String
    @ObservationIgnored private let rows: @MainActor () -> [InboxRow]
    @ObservationIgnored private let me: @MainActor () -> ParticipantID?
    @ObservationIgnored private let contacts: @MainActor () -> [HomeContact]
    var query = ""
    private(set) var pins = HomePins()
    /// Conversations shown unread by the user's Mark as Unread until they open or read them.
    private(set) var unreadMarks: Set<ConversationID> = []
    @ObservationIgnored var onSelect: (ConversationID) -> Void = { _ in }
    @ObservationIgnored var onStart: (HomeContact) -> Void = { _ in }
    #if DEBUG
    /// DEBUG: conversations listed besides the store's (`debug.home.sidebar_fixture`).
    @ObservationIgnored var debugRows: [InboxRow] = []
    #endif

    init(store: HomePinStore, account: @escaping @MainActor () -> String, rows: @escaping @MainActor () -> [InboxRow],
         me: @escaping @MainActor () -> ParticipantID?, contacts: @escaping @MainActor () -> [HomeContact]) {
        self.store = store
        self.account = account
        self.rows = rows
        self.me = me
        self.contacts = contacts
    }

    /// The store's rows (plus DEBUG fixture rows).
    private func listed() -> [InboxRow] {
        #if DEBUG
        return debugRows.isEmpty ? rows() : rows() + debugRows
        #else
        return rows()
        #endif
    }

    func model(now: Date = Date()) -> HomeSidebarModel {
        HomeSidebarModel(rows: listed(), pins: pins, me: me(), query: query, contacts: query.isEmpty ? [] : contacts(),
                         unreadMarks: unreadMarks, now: now)
    }

    func select(_ id: ConversationID) { onSelect(id) }

    func start(with contact: HomeContact) { onStart(contact) }

    /// Pins or unpins `id` and keeps it for this account.
    func setPinned(_ on: Bool, _ id: ConversationID) {
        guard let row = listed().first(where: { $0.id == id }) else { return }
        pins.setPinned(on, row)
        store.save(pins, account: account())
    }

    /// Puts `id` at `index` of the pinned grid (a drag: a new place, or a row pinned there) and
    /// keeps the order with this account's pins.
    func place(_ id: ConversationID, at index: Int) {
        let shown = HomeSidebarModel(rows: listed(), pins: pins, me: me()).pinned.map(\.id)
        pins.place(id, at: index, shown: shown)
        store.save(pins, account: account())
    }

    /// Marks `id` unread (Mark as Unread) or clears the mark (Mark as Read, opening it), and keeps
    /// the marks for this account.
    func setMarkedUnread(_ on: Bool, _ id: ConversationID) {
        guard unreadMarks.contains(id) != on else { return }
        if on { unreadMarks.insert(id) } else { unreadMarks.remove(id) }
        store.save(unreadMarks: unreadMarks, account: account())
    }

    /// The signed-in account changed: its own pins and unread marks.
    func reloadPins() {
        pins = store.pins(account: account())
        unreadMarks = store.unreadMarks(account: account())
    }
}
