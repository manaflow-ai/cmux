import CmuxNextCompat

/// Browser tabs a pane's strip lists besides its own (`browser.page.mirror`):
/// the same tab, by its own id, shown in a second pane, for example an
/// agent's tab in Home's right column while it stays in the agent's
/// workspace (plans/cmux-next/shared-browser-tabs.md).
///
/// A mirror is not a page: the tab's one page is keyed by its tab id, so the
/// pane that shows it takes the live view and the tab's own pane takes it
/// back when it shows the tab again. Session only, not restored after a
/// relaunch. Keyed per pane (`ObservedMap`): reading pane X's mirrors
/// observes pane X only.
@MainActor
public final class TabMirrors {
    private let panes = ObservedMap<String, [String]>()

    public init() {}

    /// The tabs `pane` (`PaneModel.id`) mirrors, in strip order.
    public subscript(pane: String) -> [String] {
        panes[pane] ?? []
    }

    /// Adds `tab` to `pane`'s mirrors (last in its strip); false when it was there already.
    @discardableResult
    public func add(_ tab: String, to pane: String) -> Bool {
        var tabs = self[pane]
        guard !tabs.contains(tab) else { return false }
        tabs.append(tab)
        panes[pane] = tabs
        return true
    }

    /// Shows `tab` in `pane` too and selects it in each of `memories` (the windows' selections; empty
    /// leaves the selection alone). A pane's strip observes its mirrors, so it lists the tab on its
    /// next map, and a removed mirror's pane shows its neighbor (its page goes back to the tab's own pane).
    ///
    /// - Returns: true (the pane lists it, newly or already).
    @discardableResult
    public func show(_ tab: String, in pane: String, selecting memories: [TabSelectionMemory]) -> Bool {
        add(tab, to: pane)
        for memory in memories { memory.select(tab, in: pane) }
        return true
    }

    /// Takes `tab` out of `pane`'s mirrors, or out of every pane's when `pane` is nil.
    ///
    /// - Returns: the panes it left, sorted.
    @discardableResult
    public func remove(_ tab: String, from pane: String? = nil) -> [String] {
        let candidates = pane.map { [$0] } ?? panes.keys
        var left: [String] = []
        for key in candidates {
            var tabs = self[key]
            guard let index = tabs.firstIndex(of: tab) else { continue }
            tabs.remove(at: index)
            panes[key] = tabs.isEmpty ? nil : tabs
            left.append(key)
        }
        return left.sorted()
    }

    /// Whether `pane` mirrors `tab` (observes `pane` only).
    public func mirrors(_ tab: String, in pane: String) -> Bool {
        self[pane].contains(tab)
    }
}
