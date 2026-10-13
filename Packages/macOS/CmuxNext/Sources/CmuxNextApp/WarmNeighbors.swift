/// A pane's selected tab's neighbors in its strip (two each way, so a terminal
/// behind a page counts) are the warm set's last eviction (Leo 2026-10-12,
/// tab rendering): Control-Tab either way shows a live surface, not a replay
/// re-attach behind a blank pane. Set before the switch withdraws the outgoing
/// tab, the one eviction that would hit them.
@MainActor
enum WarmNeighbors {
    static let reach = 2

    static func favor(_ pane: PaneController) {
        let order = pane.stripModel.orderedTabs.map(\.id.rawValue)
        var keys = Set<String>()
        if let selected = pane.stripModel.selectedID?.rawValue, let index = order.firstIndex(of: selected) {
            for step in 1...reach {
                keys.insert(order[(index + step) % order.count])
                keys.insert(order[(index - step % order.count + order.count) % order.count])
            }
            keys.remove(selected)
        }
        pane.services.cache.ledger.setFavored(keys, by: ObjectIdentifier(pane))
    }
}
