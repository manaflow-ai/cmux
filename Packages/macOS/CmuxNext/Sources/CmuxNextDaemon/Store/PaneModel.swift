import Foundation
public import Observation

@Observable @MainActor
public final class PaneModel: Identifiable {
    public let id: String
    public internal(set) var handle: PaneID
    /// Durable resource id (`pane_…`) on registry daemons.
    public internal(set) var resourceID: ResourceID?
    public internal(set) var name: String?
    /// Daemon default tab; the window keeps its own selection.
    public internal(set) var defaultTabIndex: Int
    public internal(set) var focusedAt: UInt64
    public internal(set) var tabs: [TabModel]
    public internal(set) var tabGroups: [TabGroupModel]
    /// Group spans over `tabs`, recomputed only when tabs or groups change.
    public private(set) var groupSpans: [TabGroupSpan] = []

    init(_ s: PaneSnapshot) {
        id = Self.identity(s)
        handle = s.id
        resourceID = s.resourceID
        name = s.name
        defaultTabIndex = s.activeTab
        focusedAt = s.focusedAt
        tabs = s.tabs.map(TabModel.init)
        tabGroups = s.tabGroups.map(TabGroupModel.init)
        recomputeSpans()
    }

    static func identity(_ s: PaneSnapshot) -> String {
        s.resourceID?.rawValue ?? "pane:\(s.id.rawValue)"
    }

    func update(_ s: PaneSnapshot) {
        if handle != s.id { handle = s.id }
        if resourceID != s.resourceID { resourceID = s.resourceID }
        if name != s.name { name = s.name }
        if defaultTabIndex != s.activeTab { defaultTabIndex = s.activeTab }
        if focusedAt != s.focusedAt { focusedAt = s.focusedAt }
        if let groups = reconcile(tabGroups, with: s.tabGroups, id: \.id, make: TabGroupModel.init, update: { $0.update($1) }) {
            tabGroups = groups
        }
        if let reordered = reconcile(tabs, with: s.tabs, id: TabModel.identity, make: TabModel.init, update: { $0.update($1) }) {
            tabs = reordered
        }
        recomputeSpans()
    }

    func insertTab(_ tab: TabModel, at index: Int) {
        tabs.insert(tab, at: min(max(index, 0), tabs.count))
        recomputeSpans()
    }

    @discardableResult
    func removeTab(surface: SurfaceID) -> TabModel? {
        guard let index = tabs.firstIndex(where: { $0.surface == surface }) else { return nil }
        let tab = tabs.remove(at: index)
        recomputeSpans()
        return tab
    }

    /// Moves the tab `surface` to `index` (clamped) inside this pane.
    func moveTab(surface: SurfaceID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.surface == surface }) else { return recomputeSpans() }
        let final = min(max(index, 0), tabs.count - 1)
        if final != from {
            var reordered = tabs
            reordered.insert(reordered.remove(at: from), at: final)
            tabs = reordered
        }
        recomputeSpans()
    }

    func recomputeSpans() {
        var spans: [TabGroupSpan] = []
        var start = 0
        while start < tabs.count {
            guard let group = tabs[start].tabGroup else {
                start += 1
                continue
            }
            var end = start + 1
            while end < tabs.count, tabs[end].tabGroup == group { end += 1 }
            spans.append(TabGroupSpan(group: group, range: start..<end))
            start = end
        }
        if spans != groupSpans { groupSpans = spans }
    }
}
