package import CmuxNextCompat
import CmuxNextSettings

/// Which tabs stay awake beside each pane's shown tab
/// (`browser.keepNeighborTabsAwake`, plans/cmux-next/neighbor-tabs-DESIGN.md).
/// Pure: `BrowserHibernation` feeds it each pane's tab order and selection.
package struct NeighborTabs {
    /// Each pane's tabs in strip order and its shown tab; keyed by the pane's presenter.
    private var panes: [ObjectIdentifier: (order: [String], selected: String?)] = [:]

    package init() {}

    /// Records a pane's order and shown tab (nil: the pane shows nothing, or is parked).
    package mutating func set(_ pane: ObjectIdentifier, order: [String], selected: String?) {
        panes[pane] = (order, selected)
    }

    package mutating func remove(_ pane: ObjectIdentifier) {
        panes[pane] = nil
    }

    /// The tabs `radius` steps before and after each pane's shown tab,
    /// wrapping as Ctrl-Tab and Cmd-Shift-[ ] do (so the last tab's next
    /// neighbor is the first), without the shown tabs themselves.
    package func awake(radius: Int) -> Set<String> {
        guard radius > 0 else { return [] }
        var keys: Set<String> = []
        var shown: Set<String> = []
        for (order, selected) in panes.values {
            guard let selected, let index = order.firstIndex(of: selected) else { continue }
            shown.insert(selected)
            keys.formUnion(Self.around(index, in: order, radius: radius))
        }
        return keys.subtracting(shown)
    }

    /// The keys within `radius` of `index`, wrapping; fewer when the pane has few tabs.
    package static func around(_ index: Int, in order: [String], radius: Int) -> [String] {
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
    package static func radius(setting: Int, pressure: MemoryPressureLevel, lowPower: Bool) -> Int {
        guard pressure == .normal, !lowPower else { return 0 }
        return max(0, min(setting, BrowserHibernationSetting.neighborRadiusRange.upperBound))
    }
}
