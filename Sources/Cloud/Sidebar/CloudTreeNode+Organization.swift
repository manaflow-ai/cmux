extension CloudTreeNode {
    /// Uses machine routing identity even when the row retains an adopted
    /// pending-create node ID. This Mac and active creates are fixed anchors.
    var machineOrderID: String? {
        guard case .machine(let machine, _) = kind, !machine.id.isEmpty else { return nil }
        return machine.id
    }

    var canReorderMachine: Bool { machineOrderID != nil }

    var showsAttentionSlot: Bool {
        switch kind {
        // Only rows that can carry the Cloud unread projection reserve the
        // leading slot. Other nested rows keep their compact identity edge.
        case .workspace, .terminal: return true
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
