public import CmuxMobileShellModel

extension MobileShellComposite {
    /// Collapse or expand a workspace group on THIS device only.
    ///
    /// Folder collapse is a per-device UI preference, not shared state: collapsing
    /// a group on the phone must not collapse it on the Mac. So this records the
    /// choice in the device-local `groupCollapseStore` and updates the in-memory
    /// `workspaceGroups` for an immediate, authoritative render. Nothing is sent to
    /// the Mac, and a later Mac `workspace.updated` will not override it (the
    /// workspace-list ingest re-applies this store). The `async` signature is kept
    /// for call-site compatibility; the work is synchronous on the main actor.
    /// - Parameters:
    ///   - id: The group to collapse or expand.
    ///   - collapsed: `true` to collapse (hide members), `false` to expand.
    public func setWorkspaceGroupCollapsed(id: MobileWorkspaceGroupPreview.ID, _ collapsed: Bool) async {
        groupCollapseStore.set(id.rawValue, collapsed: collapsed)
        if let index = workspaceGroups.firstIndex(where: { $0.id == id }) {
            workspaceGroups[index].isCollapsed = collapsed
        }
    }
}
