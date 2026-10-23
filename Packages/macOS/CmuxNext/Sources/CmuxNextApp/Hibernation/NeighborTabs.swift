import CmuxNextBridge
import CmuxNextSettings

/// Which tabs stay awake beside each pane's shown tab
/// (`browser.keepNeighborTabsAwake`, plans/cmux-next/neighbor-tabs-DESIGN.md), and how near the
/// next switch each pane's shown tab is (`fronts`). Pure: `BrowserHibernation` feeds it each
/// pane's tab order and selection.
///
/// Kept incrementally: a pane report updates that pane, its group (workspace) and at most its
/// window's group left last, and returns the fronts that moved, so a switch costs
/// O(switched panes), not O(switched panes x every mounted pane) (STRESS: 60 workspaces).
struct NeighborTabs {
    /// One pane's tabs in strip order, its shown tab, whether it is on screen and its group.
    struct Pane {
        var order: [String]
        var selected: String?
        var visible: Bool
        var group: ObjectIdentifier
    }

    /// A front that moved: its place before and after (nil: no pane shows it).
    struct FrontChange: Equatable {
        var old: HibernationPlanner.Front?
        var new: HibernationPlanner.Front?
    }

    /// One workspace's panes.
    private struct Group {
        /// The window it shows in (nil: the one window of a caller that names none).
        var window: ObjectIdentifier?
        var panes = 0
        var visiblePanes = 0
        /// Its panes' shown tabs, with how many of its panes show each.
        var shown: [String: Int] = [:]
        /// Whether `shownBy` counts its fronts as warm now.
        var warm = false
    }

    private(set) var panes: [ObjectIdentifier: Pane] = [:]
    private var groups: [ObjectIdentifier: Group] = [:]
    /// The panes on screen: only they wake neighbors.
    private var visiblePanes: Set<ObjectIdentifier> = []
    /// When each group off screen was left (a serial, the latest highest), by window.
    private var leftAt: [ObjectIdentifier?: [ObjectIdentifier: UInt64]] = [:]
    /// Each window's group left last: its fronts stay warm (the next switch back in that window).
    private var lastLeft: [ObjectIdentifier?: ObjectIdentifier] = [:]
    private var leaves: UInt64 = 0
    /// How many panes show each tab: in a warm group, and in all.
    private var shownBy: [String: (warm: Int, all: Int)] = [:]

    /// The tab each pane shows, on screen or not, and how near the next switch it is
    /// (`HibernationPlanner.Front`): warm for a group on screen (its off-screen columns) and each
    /// window's group left last (the next switch back there), parked for the rest.
    private(set) var fronts: [String: HibernationPlanner.Front] = [:]

    /// Records a pane's order and shown tab (nil: the pane shows nothing). A pane off screen (a
    /// parked workspace, an off-screen column) keeps its shown tab as its front and wakes no
    /// neighbors. `group` is the pane's workspace (nil: the pane is its own group); a group is
    /// left when its last pane on screen goes off screen. `window` is the group's window (nil:
    /// one shared window); each window keeps its own group left last.
    /// Returns the fronts that moved.
    @discardableResult
    mutating func set(_ pane: ObjectIdentifier, order: [String], selected: String?, visible: Bool = true,
                      group: ObjectIdentifier? = nil, window: ObjectIdentifier? = nil) -> [String: FrontChange] {
        let group = group ?? pane
        var changes: [String: FrontChange] = [:]
        let before = panes[pane]
        if let before { detach(pane, before, changes: &changes) }
        attach(pane, Pane(order: order, selected: selected, visible: visible, group: group), window: window, changes: &changes)
        settle(group, changes: &changes)
        if let old = before?.group, old != group { settle(old, changes: &changes) }
        return finish(changes)
    }

    /// The pane is gone. Returns the fronts that moved.
    @discardableResult
    mutating func remove(_ pane: ObjectIdentifier) -> [String: FrontChange] {
        guard let before = panes[pane] else { return [:] }
        var changes: [String: FrontChange] = [:]
        detach(pane, before, changes: &changes)
        settle(before.group, changes: &changes)
        return finish(changes)
    }

    /// Takes a pane's share out of its group.
    private mutating func detach(_ pane: ObjectIdentifier, _ state: Pane, changes: inout [String: FrontChange]) {
        panes[pane] = nil
        visiblePanes.remove(pane)
        guard var group = groups[state.group] else { return }
        group.panes -= 1
        if state.visible { group.visiblePanes -= 1 }
        if let selected = state.selected {
            group.shown[selected, default: 0] -= 1
            if group.shown[selected] == 0 { group.shown[selected] = nil }
            count(selected, warm: group.warm, by: -1, changes: &changes)
        }
        groups[state.group] = group
    }

    /// Adds a pane's share to its group (made on its first pane).
    private mutating func attach(_ pane: ObjectIdentifier, _ state: Pane, window: ObjectIdentifier?, changes: inout [String: FrontChange]) {
        panes[pane] = state
        if state.visible { visiblePanes.insert(pane) }
        if let existing = groups[state.group], existing.window != window {
            // The workspace moved to another window: its left stamp belonged to the old one.
            forgetLeft(state.group, in: existing.window, changes: &changes)
            groups[state.group]?.window = window
        }
        var group = groups[state.group] ?? Group(window: window)
        group.panes += 1
        if state.visible { group.visiblePanes += 1 }
        if let selected = state.selected {
            group.shown[selected, default: 0] += 1
            count(selected, warm: group.warm, by: 1, changes: &changes)
        }
        groups[state.group] = group
    }

    /// Stamps a group that just went off screen, forgets one on screen again or without panes,
    /// and updates whether its fronts count as warm.
    private mutating func settle(_ id: ObjectIdentifier, changes: inout [String: FrontChange]) {
        guard let group = groups[id] else { return }
        let window = group.window
        if group.panes == 0 {
            if group.warm { setWarm(id, false, changes: &changes) }
            groups[id] = nil
            forgetLeft(id, in: window, changes: &changes)
            return
        }
        if group.visiblePanes > 0 {
            forgetLeft(id, in: window, changes: &changes)
        } else if group.warm, lastLeft[window] != id {
            // Warm and not the group left last: it was on screen and just went off.
            leaves &+= 1
            leftAt[window, default: [:]][id] = leaves
            let previous = lastLeft[window]
            lastLeft[window] = id
            if let previous { refreshWarmth(previous, changes: &changes) }
        }
        refreshWarmth(id, changes: &changes)
    }

    /// Drops a group's left stamp; when it was its window's group left last, the one left before
    /// it takes its place (a scan of that window's groups off screen, only then).
    private mutating func forgetLeft(_ id: ObjectIdentifier, in window: ObjectIdentifier?, changes: inout [String: FrontChange]) {
        guard leftAt[window]?.removeValue(forKey: id) != nil else { return }
        if leftAt[window]?.isEmpty == true { leftAt[window] = nil }
        guard lastLeft[window] == id else { return }
        let next = leftAt[window]?.max { $0.value < $1.value }?.key
        lastLeft[window] = next
        if let next { refreshWarmth(next, changes: &changes) }
    }

    private mutating func refreshWarmth(_ id: ObjectIdentifier, changes: inout [String: FrontChange]) {
        guard let group = groups[id] else { return }
        let warm = group.visiblePanes > 0 || lastLeft[group.window] == id
        if warm != group.warm { setWarm(id, warm, changes: &changes) }
    }

    /// Moves a group's fronts between warm and parked (O(the group's shown tabs)).
    private mutating func setWarm(_ id: ObjectIdentifier, _ warm: Bool, changes: inout [String: FrontChange]) {
        guard let group = groups[id] else { return }
        groups[id]?.warm = warm
        for (key, panes) in group.shown {
            note(key, changes: &changes)
            shownBy[key, default: (0, 0)].warm += warm ? panes : -panes
        }
    }

    private mutating func count(_ key: String, warm: Bool, by delta: Int, changes: inout [String: FrontChange]) {
        note(key, changes: &changes)
        var counts = shownBy[key, default: (0, 0)]
        counts.all += delta
        if warm { counts.warm += delta }
        shownBy[key] = counts
    }

    /// Remembers a key's front before this report changes it.
    private func note(_ key: String, changes: inout [String: FrontChange]) {
        if changes[key] == nil { changes[key] = FrontChange(old: fronts[key], new: fronts[key]) }
    }

    /// Applies the touched keys' new fronts; returns the ones that moved.
    private mutating func finish(_ touched: [String: FrontChange]) -> [String: FrontChange] {
        var moved: [String: FrontChange] = [:]
        for (key, change) in touched {
            let counts = shownBy[key] ?? (0, 0)
            let front: HibernationPlanner.Front? = counts.warm > 0 ? .warm : counts.all > 0 ? .parked : nil
            if counts.all <= 0 { shownBy[key] = nil }
            fronts[key] = front
            if front != change.old { moved[key] = FrontChange(old: change.old, new: front) }
        }
        return moved
    }

    /// The tabs `radius` steps before and after each on-screen pane's shown tab,
    /// wrapping as Ctrl-Tab and Cmd-Shift-[ ] do (so the last tab's next
    /// neighbor is the first), without the shown tabs themselves. O(panes on screen).
    func awake(radius: Int) -> Set<String> {
        guard radius > 0 else { return [] }
        var keys: Set<String> = []
        var shown: Set<String> = []
        for id in visiblePanes {
            guard let pane = panes[id], let selected = pane.selected, let index = pane.order.firstIndex(of: selected) else { continue }
            shown.insert(selected)
            keys.formUnion(Self.around(index, in: pane.order, radius: radius))
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
