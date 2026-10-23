import CmuxNextBridge
import CmuxNextSettings

/// Which tabs stay awake beside each pane's shown tab
/// (`browser.keepNeighborTabsAwake`, plans/cmux-next/neighbor-tabs-DESIGN.md).
/// Pure: `BrowserHibernation` feeds it each pane's tab order and selection.
struct NeighborTabs {
    /// Each pane's tabs in strip order, its shown tab, whether the pane is on screen and its group
    /// (its workspace); keyed by the pane's presenter.
    private(set) var panes: [ObjectIdentifier: (order: [String], selected: String?, visible: Bool, group: ObjectIdentifier)] = [:]
    /// When each group off screen was left (a serial, the latest highest); a group on screen has none.
    private var leftAt: [ObjectIdentifier: UInt64] = [:]
    private var leaves: UInt64 = 0

    /// Records a pane's order and shown tab (nil: the pane shows nothing). A pane off screen (a
    /// parked workspace, an off-screen column) keeps its shown tab as its front and wakes no
    /// neighbors. `group` is the pane's workspace (nil: the pane is its own group); a group is
    /// left when its last pane on screen goes off screen.
    mutating func set(_ pane: ObjectIdentifier, order: [String], selected: String?, visible: Bool = true, group: ObjectIdentifier? = nil) {
        let group = group ?? pane
        var groups = [group]
        if let before = panes[pane]?.group, before != group { groups.append(before) }
        let wasOnScreen = groups.map { isOnScreen($0) }
        panes[pane] = (order, selected, visible, group)
        for (group, was) in zip(groups, wasOnScreen) { settle(group, wasOnScreen: was) }
    }

    /// The tab each pane shows, on screen or not, and how near the next switch it is
    /// (`HibernationPlanner.Front`): warm for a group on screen (its off-screen columns) and the
    /// group left last (the next switch back), parked for the rest.
    var fronts: [String: HibernationPlanner.Front] {
        let onScreen = Set(panes.values.filter { $0.visible }.map { $0.group })
        let lastLeft = leftAt.max { $0.value < $1.value }?.key
        var fronts: [String: HibernationPlanner.Front] = [:]
        for pane in panes.values {
            guard let selected = pane.selected else { continue }
            let warm = onScreen.contains(pane.group) || pane.group == lastLeft
            if warm || fronts[selected] == nil { fronts[selected] = warm ? .warm : .parked }
        }
        return fronts
    }

    mutating func remove(_ pane: ObjectIdentifier) {
        guard let group = panes[pane]?.group else { return }
        let was = isOnScreen(group)
        panes[pane] = nil
        settle(group, wasOnScreen: was)
    }

    private func isOnScreen(_ group: ObjectIdentifier) -> Bool {
        panes.values.contains { $0.group == group && $0.visible }
    }

    /// Stamps a group that just went off screen; forgets one on screen again or without panes.
    private mutating func settle(_ group: ObjectIdentifier, wasOnScreen: Bool) {
        if isOnScreen(group) || !panes.values.contains(where: { $0.group == group }) {
            leftAt[group] = nil
        } else if wasOnScreen {
            leaves &+= 1
            leftAt[group] = leaves
        }
    }

    /// The tabs `radius` steps before and after each pane's shown tab,
    /// wrapping as Ctrl-Tab and Cmd-Shift-[ ] do (so the last tab's next
    /// neighbor is the first), without the shown tabs themselves.
    func awake(radius: Int) -> Set<String> {
        guard radius > 0 else { return [] }
        var keys: Set<String> = []
        var shown: Set<String> = []
        for (order, selected, visible, _) in panes.values {
            guard visible, let selected, let index = order.firstIndex(of: selected) else { continue }
            shown.insert(selected)
            keys.formUnion(Self.around(index, in: order, radius: radius))
        }
        return keys.subtracting(shown)
    }

    /// The keys within `radius` of `index`, wrapping; fewer when the pane has few tabs.
    static func around(_ index: Int, in order: [String], radius: Int) -> [String] {
        let count = order.count
        guard count > 1, radius > 0 else { return [] }
        var keys: [String] = []
        for step in 1...min(radius, count - 1) {
            for offset in [-step, step] {
                let key = order[((index + offset) % count + count) % count]
                if key != order[index], !keys.contains(key) { keys.append(key) }
            }
        }
        return keys
    }

    /// The radius in effect: the setting, or 0 under memory pressure or in Low Power Mode.
    static func radius(setting: Int, pressure: MemoryPressureLevel, lowPower: Bool) -> Int {
        guard pressure == .normal, !lowPower else { return 0 }
        return max(0, min(setting, BrowserHibernationSetting.neighborRadiusRange.upperBound))
    }
}
