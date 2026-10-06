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

    func pins(account: String) -> HomePins { HomePins() }

    func save(_ pins: HomePins, account: String) {}
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
    @ObservationIgnored var onSelect: (ConversationID) -> Void = { _ in }
    @ObservationIgnored var onStart: (HomeContact) -> Void = { _ in }

    init(store: HomePinStore, account: @escaping @MainActor () -> String, rows: @escaping @MainActor () -> [InboxRow],
         me: @escaping @MainActor () -> ParticipantID?, contacts: @escaping @MainActor () -> [HomeContact]) {
        self.store = store
        self.account = account
        self.rows = rows
        self.me = me
        self.contacts = contacts
    }

    func model(now: Date = Date()) -> HomeSidebarModel {
        HomeSidebarModel(rows: [], pins: pins, me: me(), query: query, contacts: [], now: now)
    }

    func select(_ id: ConversationID) {}

    func start(with contact: HomeContact) {}

    func setPinned(_ on: Bool, _ id: ConversationID) {}

    /// The signed-in account changed: its own pins.
    func reloadPins() {}
}
