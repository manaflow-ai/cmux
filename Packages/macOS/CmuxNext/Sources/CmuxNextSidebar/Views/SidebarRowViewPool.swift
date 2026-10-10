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

    /// `key`'s parked view, reset; else a new one.
    mutating func take(for key: SidebarRowKey) -> SidebarRowView {
        if let parked = views.removeValue(forKey: key) {
            order.removeAll { $0 == key }
            parked.prepareForReuse(key: key)
            return parked
        }
        return Self.rowClass(for: key).init(key: key)
    }

    /// Parks a view that left the list (already removed from its superview)
    /// under its own row's key.
    mutating func put(_ view: SidebarRowView) {
        if views.updateValue(view, forKey: view.key) == nil { order.append(view.key) }
        while order.count > Self.limit { views[order.removeFirst()] = nil }
    }

    private static func rowClass(for key: SidebarRowKey) -> SidebarRowView.Type {
        switch key {
        case .workspace: WorkspaceRowView.self
        case .tab: SidebarTabRowView.self
        case .group: GroupHeaderRowView.self
        case .section: SectionHeaderRowView.self
        case .emptySection: EmptySectionRowView.self
        case .folder: FolderHeaderRowView.self
        }
    }
}
