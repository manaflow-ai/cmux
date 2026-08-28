import Foundation

/// User customization of the right sidebar's mode tabs: which tabs are shown
/// and in what order. Feature availability (beta toggles, Cloud rollout) stays
/// in `RightSidebarMode.isAvailable`; this layer only stores the user's
/// choices on top of it, so a tab hidden here can still be revealed by an
/// explicit selection (CLI, command palette, notification routing).
enum RightSidebarTabPreferences {
    static let orderKey = "rightSidebar.tabs.order"
    static let hiddenKey = "rightSidebar.tabs.hidden"

    /// Posted after any mutation. Mutations also post
    /// `KeyboardShortcutSettings.didChangeNotification` because the positional
    /// digit-shortcut defaults (`ctrl+1…9` follow the visible tab order) change
    /// with these preferences and every shortcut matcher/hint cache keys off
    /// that notification.
    static let didChangeNotification = Notification.Name("RightSidebarTabPreferencesDidChange")

    /// Every customizable tab in the user's order. Tabs missing from the
    /// stored order (new modes shipped after the user last reordered) keep
    /// their canonical position relative to the stored ones by appending in
    /// declaration order. `customSidebar` is not a bar tab and never appears.
    nonisolated static func orderedModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        let canonical = RightSidebarMode.allCases.filter { $0 != .customSidebar }
        let stored = (defaults.stringArray(forKey: orderKey) ?? [])
            .compactMap(RightSidebarMode.init(rawValue:))
        var result: [RightSidebarMode] = []
        for mode in stored where canonical.contains(mode) && !result.contains(mode) {
            result.append(mode)
        }
        for mode in canonical where !result.contains(mode) {
            result.append(mode)
        }
        return result
    }

    nonisolated static func hiddenModes(defaults: UserDefaults = .standard) -> Set<RightSidebarMode> {
        Set((defaults.stringArray(forKey: hiddenKey) ?? []).compactMap(RightSidebarMode.init(rawValue:)))
    }

    nonisolated static func isHidden(_ mode: RightSidebarMode, defaults: UserDefaults = .standard) -> Bool {
        hiddenModes(defaults: defaults).contains(mode)
    }

    /// Hides or shows one tab. Refuses to hide the last visible tab so the
    /// sidebar always has a mode to land on.
    @discardableResult
    static func setHidden(_ hidden: Bool, mode: RightSidebarMode, defaults: UserDefaults = .standard) -> Bool {
        guard mode != .customSidebar else { return false }
        var hiddenSet = hiddenModes(defaults: defaults)
        if hidden {
            guard hiddenSet.insert(mode).inserted else { return true }
            guard RightSidebarMode.visibleModes(defaults: defaults).contains(where: { $0 != mode }) else {
                return false
            }
        } else {
            guard hiddenSet.remove(mode) != nil else { return true }
        }
        defaults.set(hiddenSet.map(\.rawValue).sorted(), forKey: hiddenKey)
        notifyChanged()
        return true
    }

    /// Rewrites the relative order of the modes in `displayed` (the mode bar's
    /// pills, left to right) while every other tab keeps its slot in the full
    /// order. Used by drag-to-reorder: the bar shows a subset (hidden tabs are
    /// absent, except a revealed active one), so only that subset's slots are
    /// permuted.
    static func setDisplayedOrder(_ displayed: [RightSidebarMode], defaults: UserDefaults = .standard) {
        var queue = displayed.filter { $0 != .customSidebar }
        let displayedSet = Set(queue)
        let currentOrder = orderedModes(defaults: defaults)
        var order = currentOrder
        for index in order.indices where displayedSet.contains(order[index]) {
            guard !queue.isEmpty else { break }
            order[index] = queue.removeFirst()
        }
        guard order != currentOrder else { return }
        defaults.set(order.map(\.rawValue), forKey: orderKey)
        notifyChanged()
    }

    /// Moves one tab by `offset` within the full ordered tab list (hidden tabs
    /// keep their slot so re-showing one restores its place).
    static func move(_ mode: RightSidebarMode, offset: Int, defaults: UserDefaults = .standard) {
        var order = orderedModes(defaults: defaults)
        guard let index = order.firstIndex(of: mode) else { return }
        let target = max(0, min(order.count - 1, index + offset))
        guard target != index else { return }
        order.remove(at: index)
        order.insert(mode, at: target)
        defaults.set(order.map(\.rawValue), forKey: orderKey)
        notifyChanged()
    }

    static func resetToDefaults(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: orderKey)
        defaults.removeObject(forKey: hiddenKey)
        notifyChanged()
    }

    private static func notifyChanged() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        NotificationCenter.default.post(name: KeyboardShortcutSettings.didChangeNotification, object: nil)
    }
}
