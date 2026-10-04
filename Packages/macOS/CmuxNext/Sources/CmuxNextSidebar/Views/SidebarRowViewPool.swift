import AppKit

/// Recycled sidebar row views by row class. Views exist only for rows near
/// the viewport; leaving rows wait here (bounded per class) for reuse
/// instead of being deallocated.
@MainActor
struct SidebarRowViewPool {
    /// Upper bound per row class; enough for a tall window plus overscan.
    static let limit = 48
    private var views: [ObjectIdentifier: [SidebarRowView]] = [:]

    /// A recycled view of `key`'s row class, reset for `key`; else a new one.
    mutating func take(for key: SidebarRowKey) -> SidebarRowView {
        let type = Self.rowClass(for: key)
        if let recycled = views[ObjectIdentifier(type)]?.popLast() {
            recycled.prepareForReuse(key: key)
            return recycled
        }
        return type.init(key: key)
    }

    /// Keeps a view that left the list (already removed from its superview).
    mutating func put(_ view: SidebarRowView) {
        let id = ObjectIdentifier(type(of: view))
        guard views[id, default: []].count < Self.limit else { return }
        views[id, default: []].append(view)
    }

    private static func rowClass(for key: SidebarRowKey) -> SidebarRowView.Type {
        switch key {
        case .workspace: WorkspaceRowView.self
        case .tab: SidebarTabRowView.self
        case .group: GroupHeaderRowView.self
        case .section: SectionHeaderRowView.self
        case .emptySection: EmptySectionRowView.self
        }
    }
}
