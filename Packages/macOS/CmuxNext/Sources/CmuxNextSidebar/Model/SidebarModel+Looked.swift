extension SidebarModel {
    /// The selection left `old`: a member of a collapsed group keeps drawing beside the active one,
    /// and the workspace is stamped as last looked at now (`SidebarLookedStore`).
    func noteLeft(_ old: SidebarItem?) {
        guard case let .workspace(id)? = old else { return }
        if let group = collapsedGroup(of: id) { revealedMembers[group, default: []].insert(id) }
        // Only the hover card's "since you looked" line reads the stamps.
        if SidebarTunables.sinceLooked.value { SidebarLookedStore.shared.stamp(id) }
    }
}
