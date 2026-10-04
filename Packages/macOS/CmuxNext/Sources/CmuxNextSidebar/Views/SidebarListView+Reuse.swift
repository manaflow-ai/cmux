import AppKit
// Row view reuse through `rowPool`: views exist only for rows near the
// viewport, and leaving rows return to the pool.
extension SidebarListView {
    func dequeue(_ key: SidebarRowKey) -> SidebarRowView {
        let view = rowPool.take(for: key)
        wire(view, key: key)
        return view
    }
    func recycle(_ view: SidebarRowView) {
        view.removeFromSuperview()
        rowPool.put(view)
    }
    /// Per-key callbacks, set on every dequeue so recycled views never keep
    /// a previous row's target.
    private func wire(_ view: SidebarRowView, key: SidebarRowKey) {
        switch (key, view) {
        case let (.workspace(id), view as WorkspaceRowView):
            view.onClose = { [weak self] in self?.model.send(.close([id])) }
        case (.tab, _):
            break
        case let (.group(id), view as GroupHeaderRowView):
            guard let row = displayed.row(for: .group(id)) else { return }
            view.onAdd = { [weak self] in
                guard let self, case let .machine(machine) = self.sections[row.section]?.kind else { return }
                self.model.send(.newWorkspace(machine: machine.id, group: id))
            }
            view.onEdit = { [weak self] in self?.inlineRename.begin(.group(id)) }
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
