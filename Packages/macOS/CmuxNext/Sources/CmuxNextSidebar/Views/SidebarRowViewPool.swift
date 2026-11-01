import AppKit

/// Off-screen sidebar row views, keyed by their row's stable id (cx-ai79).
/// Views exist only for rows near the viewport; a row that scrolls away waits
/// here and gets its own view back. A view is never rebound to another row:
/// a new workspace always gets a new view, so no view flies in from another
/// row's place or crossfades over it.
@MainActor
struct SidebarRowViewPool {
    /// Upper bound on parked views. Parked views stay in the list, hidden, so each one is a subtree
    /// AppKit walks on every scroll frame: the list sets this to two realization rects of rows
    /// (`limit(forHeight:rowHeight:)`). A scroll keeps few parked (it rebinds them); a space
    /// switch parks the page it leaves before it takes back the other space's rows by key.
    var limit = 64

    /// The parked views a list `height` points tall needs: two pages of its rows at the shortest
    /// row height (the page a space switch leaves and the one it takes back), at least 32.
    static func limit(forHeight height: CGFloat, rowHeight: CGFloat) -> Int {
        max(32, 2 * Int((height / max(rowHeight, 1)).rounded(.up)))
    }
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
        while order.count > limit {
            if let old = views.removeValue(forKey: order.removeFirst()) { evicted.append(old) }
        }
        return evicted
    }

    private static func rowClass(for key: SidebarRowKey) -> SidebarRowView.Type {
        switch key {
        case .workspace: WorkspaceRowView.self
        case .item: SidebarItemListRowView.self
        case .block: SidebarBlockRowView.self
        case .group: GroupHeaderRowView.self
        case .section: SectionHeaderRowView.self
        case .emptySection: EmptySectionRowView.self
        case .emptyGroup: EmptyGroupRowView.self
        case .folder: FolderHeaderRowView.self
        case .status: StatusHeaderRowView.self
        case .doneFold, .showMore: SidebarDoneFoldRowView.self
        }
    }
}
