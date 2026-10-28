import CmuxHomeCore
import CmuxNextHome
import Foundation

/// The one-time move of this Mac's Messages-list pins into the owners (hq-6d cx-frn2y, 2026-10-15). Before
/// `home-inbox` the Messages list kept its pins per account on this Mac (`HomePinStore`); now the owner
/// keeps the pins of every row it lists, so both Home views show the same ones, and a pin kept here
/// would be ignored for those rows. After each owner reply (`HomeInboxSource.onRows`) each pin kept here
/// for a row that owner lists goes to it (`conversation-inbox-op` for the Chief home's rows,
/// `cloud-inbox-op` for the Cloud rows), in this Mac's order after the person's other pins, and leaves
/// this Mac once the owner accepted it. That removal is the record: a moved pin is never sent again, so
/// an unpin made later in either view stays. This Mac's unpins (of a default pin) are not moved: the
/// owner pins no row by default, so its pin is the person's own, maybe newer (made in Channels or on
/// another device), and an unpin sent now could take it away. A pin the owner refused stays here and is not sent again
/// this launch (the next launch tries once more), so a refusing owner gets no loop of requests; an
/// unavailable Cloud is not asked. Pins of rows no owner lists (yet) stay here. Chiefs pinned only by
/// default (not in the person's own order) are not moved: the owner pins no Chief by default.
@MainActor
public final class HomePinMigration {
    private let store: HomePinStore
    private let account: @MainActor () -> String
    /// Ids sent and not answered yet, and ids an owner refused this launch: not sent (again).
    private var sending: Set<String> = []
    private var refused: Set<String> = []

    public init(store: HomePinStore = HomePinStore(), account: @escaping @MainActor () -> String) {
        self.store = store
        self.account = account
    }

    /// Runs after each reply of each owner.
    public func attach(_ inboxes: [HomeInboxSource]) {
        for inbox in inboxes {
            inbox.onRows = { [weak self, weak inbox] in
                guard let self, let inbox else { return }
                run(inbox)
            }
        }
    }

    /// Moves the pins kept here for rows `inbox` lists; drops at once the ones it already pins.
    func run(_ inbox: HomeInboxSource) {
        guard let reply = inbox.reply, reply.cloud != "unavailable", !reply.rows.isEmpty else { return }
        let account = account()
        let kept = store.pins(account: account)
        let listed = Dictionary(reply.rows.map { ($0.id, $0.pinned) }, uniquingKeysWith: { first, _ in first })
        let open = { (id: String) in listed[id] != nil && !self.sending.contains(id) && !self.refused.contains(id) }
        let pins = kept.pinned.map(\.rawValue).filter(open)
        // Already pinned there: nothing to send, this Mac's copy goes.
        let same = pins.filter { listed[$0] == true }
        if !same.isEmpty { drop(same, account: account) }
        let ids = pins.filter { listed[$0] == false }
        guard !ids.isEmpty else { return }
        sending.formUnion(ids)
        inbox.adopt(pins: ids) { [weak self] accepted in
            guard let self else { return }
            sending.subtract(ids)
            refused.formUnion(Set(ids).subtracting(accepted))
            if !accepted.isEmpty { drop(accepted, account: account) }
        }
    }

    /// Takes `ids` out of this Mac's pins for `account`.
    private func drop(_ ids: [String], account: String) {
        let gone = Set(ids)
        var pins = store.pins(account: account)
        pins.pinned.removeAll { gone.contains($0.rawValue) }
        store.save(pins, account: account)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// DEBUG (`debug.home.drive {action: legacy_pins}`): the pins this Mac keeps for the account, after
    /// setting them to `pins` when given (a GUI proof seeds the old store, then relaunches).
    public func debugPins(_ pins: [String]?) -> [String] {
        let account = account()
        if let pins {
            var kept = store.pins(account: account)
            kept.pinned = pins.map { ConversationID($0) }
            store.save(kept, account: account)
        }
        return store.pins(account: account).pinned.map(\.rawValue)
    }
    #endif
}
