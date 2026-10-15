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
/// an unpin made later in either view stays. A pin the owner refused stays here and goes at a later
/// reply. Pins of rows no owner lists (yet) stay here. Chiefs pinned only by default (not in the
/// person's own order) are not moved: the owner's rows pin no Chief by default (the Channels rule).
@MainActor
public final class HomePinMigration {
    private let store: HomePinStore
    private let account: @MainActor () -> String
    /// Pins sent and not answered yet: the next reply does not send them again.
    private var sending: Set<String> = []

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
        guard let rows = inbox.rows, !rows.isEmpty else { return }
        let account = account()
        let kept = store.pins(account: account).pinned.map(\.rawValue)
        let listed = Dictionary(rows.map { ($0.id, $0.pinned) }, uniquingKeysWith: { first, _ in first })
        let mine = kept.filter { listed[$0] != nil && !sending.contains($0) }
        guard !mine.isEmpty else { return }
        let already = mine.filter { listed[$0] == true }
        if !already.isEmpty { drop(already, account: account) }
        let move = mine.filter { listed[$0] == false }
        guard !move.isEmpty else { return }
        sending.formUnion(move)
        inbox.adopt(pins: move) { [weak self] accepted in
            guard let self else { return }
            sending.subtract(move)
            if !accepted.isEmpty { drop(accepted, account: account) }
        }
    }

    private func drop(_ ids: [String], account: String) {
        let gone = Set(ids)
        var pins = store.pins(account: account)
        pins.pinned.removeAll { gone.contains($0.rawValue) }
        store.save(pins, account: account)
    }

    #if DEBUG
    /// DEBUG (`debug.home.drive {action: legacy_pins}`): the pins this Mac keeps for the account, after
    /// setting them to `pins` when given (a GUI proof seeds the old store, then relaunches).
    public func debugPins(_ pins: [String]?) -> [String] {
        let account = account()
        if let pins {
            var kept = store.pins(account: account)
            kept.pinned = pins.map(ConversationID.init)
            store.save(kept, account: account)
        }
        return store.pins(account: account).pinned.map(\.rawValue)
    }
    #endif
}
