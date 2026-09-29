import AppKit

// Row view reuse: views exist only for rows near the viewport, and leaving
// rows return to a small per-class pool instead of being deallocated.

extension SidebarListView {
    /// Upper bound per row class; enough for a tall window plus overscan.
    static let reusePoolLimit = 48

    func dequeue(_ key: SidebarRowKey) -> SidebarRowView {
        let type = rowClass(for: key)
        let view: SidebarRowView
        if let recycled = reusePool[ObjectIdentifier(type)]?.popLast() {
            view = recycled
            view.prepareForReuse(key: key)
        } else {
            view = type.init(key: key)
        }
        wire(view, key: key)
        return view
    }

    func recycle(_ view: SidebarRowView) {
        view.removeFromSuperview()
        let id = ObjectIdentifier(type(of: view))
        guard reusePool[id, default: []].count < Self.reusePoolLimit else { return }
        reusePool[id, default: []].append(view)
    }

    private func rowClass(for key: SidebarRowKey) -> SidebarRowView.Type {
        switch key {
        case .workspace: WorkspaceRowView.self
        case .group: GroupHeaderRowView.self
        case .section: SectionHeaderRowView.self
        case .emptySection: EmptySectionRowView.self
        }
    }

    /// Per-key callbacks, set on every dequeue so recycled views never keep
    /// a previous row's target.
    private func wire(_ view: SidebarRowView, key: SidebarRowKey) {
        switch (key, view) {
        case let (.workspace(id), view as WorkspaceRowView):
            view.onClose = { [weak self] in self?.model.send(.close([id])) }
        case let (.section(sectionID), view as SectionHeaderRowView):
            if case let .machine(machine) = sectionID {
                view.allowsAdd = true
                view.onAdd = { [weak self] in self?.model.send(.newWorkspace(machine: machine, group: nil)) }
            } else {
                view.allowsAdd = false
                view.onAdd = nil
            }
        default:
            break
        }
    }
}
