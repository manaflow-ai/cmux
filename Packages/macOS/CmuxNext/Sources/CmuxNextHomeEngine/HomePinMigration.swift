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

    /// Moves the pins kept here for rows `inbox` lists; drops at once the ones it already pins
    /// (`dock.pin_migration_run`).
    func run(_ inbox: HomeInboxSource) {
        guard let reply = inbox.reply else { return }
        let account = account()
        let kept = store.pins(account: account)
        let request = RunRequest(cloud: reply.cloud, rows: reply.rows.map { PinRow(id: $0.id, pinned: $0.pinned) },
                                 kept: kept.pinned.map(\.rawValue), sending: sending.sorted(), refused: refused.sorted())
        let plan: RunPlan = dockRule("dock.pin_migration_run", request, fallback: RunPlan(drop: [], send: [], sending: request.sending))
        // Already pinned there: nothing to send, this Mac's copy goes.
        if !plan.drop.isEmpty { drop(plan.drop, account: account) }
        let ids = plan.send
        guard !ids.isEmpty else { return }
        sending = Set(plan.sending)
        inbox.adopt(pins: ids) { [weak self] accepted in
            guard let self else { return }
            let answer: Adopted = dockRule("dock.pin_migration_adopted",
                                           AdoptedRequest(ids: ids, accepted: accepted, sending: sending.sorted(), refused: refused.sorted()),
                                           fallback: Adopted(sending: sending.subtracting(ids).sorted(), refused: refused.sorted(), drop: []))
            sending = Set(answer.sending)
            refused = Set(answer.refused)
            if !answer.drop.isEmpty { drop(answer.drop, account: account) }
        }
    }

    /// Takes `ids` out of this Mac's pins for `account` (`dock.pin_drop`; its unpins stay).
    private func drop(_ ids: [String], account: String) {
        var pins = store.pins(account: account)
        let kept: StoredPins = dockRule("dock.pin_drop",
                                        DropRequest(pins: StoredPins(pinned: pins.pinned.map(\.rawValue), positions: pins.positions), gone: ids),
                                        fallback: StoredPins(pinned: pins.pinned.map(\.rawValue), positions: pins.positions))
        pins.pinned = kept.pinned.map { ConversationID($0) }
        pins.positions = kept.positions
        store.save(pins, account: account)
    }

    private nonisolated struct PinRow: Encodable { var id: String; var pinned: Bool }
    private nonisolated struct RunRequest: Encodable {
        var cloud: String?
        var rows: [PinRow]
        var kept: [String]
        var sending: [String]
        var refused: [String]
    }
    private nonisolated struct RunPlan: Decodable { var drop: [String]; var send: [String]; var sending: [String] }
    private nonisolated struct AdoptedRequest: Encodable {
        var ids: [String]
        var accepted: [String]
        var sending: [String]
        var refused: [String]
    }
    private nonisolated struct Adopted: Decodable { var sending: [String]; var refused: [String]; var drop: [String] }
    private nonisolated struct StoredPins: Codable { var pinned: [String]; var positions: [String: UInt64] }
    private nonisolated struct DropRequest: Encodable { var pins: StoredPins; var gone: [String] }

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
