extension SidebarModel {
    /// The selection left `old`: a member of a collapsed group keeps drawing beside the active one,
    /// and the workspace is stamped as last looked at now (`SidebarLookedStore`).
    func noteLeft(_ old: SidebarItem?) {
        guard case let .workspace(id)? = old else { return }
        if let group = collapsedGroup(of: id) { revealedMembers[group, default: []].insert(id) }
        SidebarLookedStore.shared.stamp(id)
    }

    /// Collapsed groups stop drawing the members the selection left (`revealedMembers`); only the active one stays.
    /// Returns whether any group drew one.
    func forgetRevealedMembers() -> Bool {
        guard !revealedMembers.isEmpty else { return false }
        revealedMembers = [:]
        return true
    }
}
