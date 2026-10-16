extension CloudTreeNode {
    /// Uses machine routing identity even when the row retains an adopted
    /// pending-create node ID. This Mac and active creates are fixed anchors.
    var machineOrderID: String? {
        guard case .machine(let machine, _) = kind, !machine.id.isEmpty else { return nil }
        return machine.id
    }

    var canReorderMachine: Bool { machineOrderID != nil }

    /// Rows whose cell spans the whole row, so their hover fill and click
    /// target stretch edge to edge (`CloudTreeNSOutlineView.frameOfCell`).
    var spansFullRowWidth: Bool {
        switch kind {
        case .devicesEmpty, .createAction, .machineDetailTabs: return true
        default: return false
        }
    }

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
        case .terminal(let row): return row.hasUnreadNotification
        case .workspace: return hasUnreadDescendant
        default: return false
        }
    }

    var hasUnreadDescendant: Bool {
        children.contains { child in
            if case .terminal(let row) = child.kind { return row.hasUnreadNotification }
            return child.hasUnreadDescendant
        }
    }

    /// The key a row's children are ordered and pinned under. The sidebar
    /// shows a machine's workspaces directly under its row
    /// (`CloudTreeMachineDetailLayout`), but their saved order stays keyed by
    /// the Workspaces group the catalog builds.
    var organizationGroupID: String {
        if case .machine = kind { return CloudTreeNodeBuilder.nodeID(workspacesGroup: machine) }
        return id
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
