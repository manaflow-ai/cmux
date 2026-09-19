extension CloudTreeNode {
    var showsAttentionSlot: Bool {
        switch kind {
        // Surface, resource, and empty-state rows share a leading attention
        // column so every nested row uses the same horizontal rhythm.
        case .workspace, .localWorkspace, .terminal, .display, .browser, .port, .resource, .placeholder: return true
        default: return false
        }
    }

    var hasUnreadAttention: Bool {
        switch kind {
        case .terminal, .workspace, .localWorkspace: return hasUnreadNotification
        default: return false
        }
    }

    var hasUnreadDescendant: Bool {
        children.contains { $0.hasUnreadNotification }
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
