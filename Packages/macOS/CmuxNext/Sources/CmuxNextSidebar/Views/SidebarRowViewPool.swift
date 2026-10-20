import AppKit

/// Off-screen sidebar row views, keyed by their row's stable id (cx-ai79).
/// Views exist only for rows near the viewport; a row that scrolls away waits
/// here and gets its own view back. A view is never rebound to another row:
/// a new workspace always gets a new view, so no view flies in from another
/// row's place or crossfades over it.
@MainActor
struct SidebarRowViewPool {
    /// Upper bound on parked views; enough for a tall window plus overscan.
    static let limit = 96
    private var views: [SidebarRowKey: SidebarRowView] = [:]
    /// Parked keys, oldest first, for eviction.
    private var order: [SidebarRowKey] = []

    /// `key`'s parked view, reset; else, when `rebinding`, the oldest parked
    /// view of the same kind, reset for `key` (scroll realization: a long
    /// scroll makes no new views); else a new one.
    mutating func take(for key: SidebarRowKey, rebinding: Bool = false) -> SidebarRowView {
        if let parked = views.removeValue(forKey: key) {
            order.removeAll { $0 == key }
            parked.prepareForReuse(key: key)
            return parked
        }
        let rowClass = Self.rowClass(for: key)
        if rebinding, let index = order.firstIndex(where: { views[$0].map { type(of: $0) == rowClass } ?? false }),
           let parked = views.removeValue(forKey: order[index]) {
            order.remove(at: index)
            parked.prepareForReuse(key: key)
            return parked
        }
        return rowClass.init(key: key)
    }

    /// Parks a view that left the list (hidden in it, or removed from its
    /// superview) under its own row's key; returns the views it evicted.
    @discardableResult
    mutating func put(_ view: SidebarRowView) -> [SidebarRowView] {
        if let replaced = views.updateValue(view, forKey: view.key) {
            return replaced === view ? [] : [replaced]
        }
        order.append(view.key)
        var evicted: [SidebarRowView] = []
        while order.count > Self.limit {
            if let old = views.removeValue(forKey: order.removeFirst()) { evicted.append(old) }
        }
        return evicted
    }

    private static func rowClass(for key: SidebarRowKey) -> SidebarRowView.Type {
        switch key {
        case .workspace: WorkspaceRowView.self
        case .item: SidebarItemListRowView.self
        case .block: SidebarBlockRowView.self
        case .tab: SidebarTabRowView.self
        case .group: GroupHeaderRowView.self
        case .section: SectionHeaderRowView.self
        case .emptySection: EmptySectionRowView.self
        case .folder: FolderHeaderRowView.self
        case .status: StatusHeaderRowView.self
        }
    }
}
