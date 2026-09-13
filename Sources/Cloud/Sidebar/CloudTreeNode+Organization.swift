extension CloudTreeNode {
    var hasUnreadDescendant: Bool {
        children.contains { child in
            if case .terminal(let row) = child.kind { return row.hasUnreadNotification }
            return child.hasUnreadDescendant
        }
    }

    /// Cloud folders and their leaf rows can be organized within their owning
    /// group. Local workspaces continue to use the existing left-sidebar owner.
    var canOrganize: Bool {
        guard !machine.isLocal else { return false }
        switch kind {
        case .workspace, .terminal, .display, .browser, .port: return true
        default: return false
        }
    }
}
