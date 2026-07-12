internal import CmuxMobileRPC
internal import CmuxMobileShellModel

extension MobileShellComposite {
    /// Applies a focus-only event without fetching or decoding the full list.
    func applyWorkspaceFocusEvent(_ event: MobileWorkspaceFocusEvent, macID: String?) {
        if let macID {
            guard var state = workspacesByMac[macID],
                  let index = state.workspaces.firstIndex(where: {
                      $0.rpcWorkspaceID.rawValue == event.workspaceID
                  }) else { return }
            state.workspaces[index].applyFocusSnapshot(event)
            workspacesByMac[macID] = state
            recordWorkspaceFocusEvent(event, macID: macID)
            return
        }
        var applied = false
        mutateForegroundWorkspaces { workspaces in
            guard let index = workspaces.firstIndex(where: {
                $0.rpcWorkspaceID.rawValue == event.workspaceID
            }) else { return }
            workspaces[index].applyFocusSnapshot(event)
            applied = true
        }
        if applied {
            recordWorkspaceFocusEvent(event, macID: foregroundMacDeviceID)
        }
    }

    func workspaceFocusRevisionSnapshot() -> UInt64 {
        workspaceFocusEventRevision
    }

    func preserveNewerWorkspaceFocusIfNeeded(
        in workspace: inout MobileWorkspacePreview,
        from existingWorkspace: MobileWorkspacePreview,
        macID: String?,
        listStartedAtFocusRevision: UInt64
    ) {
        let ownerKey = workspaceFocusOwnerKey(macID: macID)
        let revision = workspaceFocusEventRevisionsByMac[ownerKey]?[workspace.rpcWorkspaceID.rawValue] ?? 0
        guard revision > listStartedAtFocusRevision else { return }
        workspace.preserveFocusSnapshot(from: existingWorkspace)
    }

    func pruneWorkspaceFocusRevisions(
        macID: String?,
        retainingRemoteWorkspaceIDs: Set<String>
    ) {
        let ownerKey = workspaceFocusOwnerKey(macID: macID)
        workspaceFocusEventRevisionsByMac[ownerKey] =
            workspaceFocusEventRevisionsByMac[ownerKey]?.filter {
                retainingRemoteWorkspaceIDs.contains($0.key)
            }
        if workspaceFocusEventRevisionsByMac[ownerKey]?.isEmpty == true {
            workspaceFocusEventRevisionsByMac[ownerKey] = nil
        }
    }

    private func recordWorkspaceFocusEvent(
        _ event: MobileWorkspaceFocusEvent,
        macID: String?
    ) {
        workspaceFocusEventRevision &+= 1
        let ownerKey = workspaceFocusOwnerKey(macID: macID)
        workspaceFocusEventRevisionsByMac[ownerKey, default: [:]][event.workspaceID] =
            workspaceFocusEventRevision
    }

    /// Resolves one stable focus-revision owner through foreground promotion.
    /// During connect, the ticket identifies the Mac before the foreground state
    /// is promoted, so every writer and reader must use the same fallback order.
    func workspaceFocusOwnerKey(macID: String?) -> String {
        if let macID, !macID.isEmpty { return macID }
        if let foregroundMacDeviceID, !foregroundMacDeviceID.isEmpty { return foregroundMacDeviceID }
        if let ticketMacDeviceID = activeTicket?.macDeviceID, !ticketMacDeviceID.isEmpty {
            return ticketMacDeviceID
        }
        return Self.foregroundAnonymousKey
    }
}

extension MobileWorkspacePreview {
    mutating func applyFocusSnapshot(_ event: MobileWorkspaceFocusEvent) {
        let paneID = event.focusedPaneID.map(MobilePanePreview.ID.init(rawValue:))
        let terminalID = event.selectedTerminalID.map(MobileTerminalPreview.ID.init(rawValue:))
        focusedPaneID = paneID
        selectedTerminalID = terminalID
        for index in panes.indices {
            panes[index].isFocused = panes[index].id == paneID
        }
        for index in terminals.indices {
            terminals[index].isFocused = terminals[index].id == terminalID
        }
    }

    mutating func preserveFocusSnapshot(from existing: MobileWorkspacePreview) {
        focusedPaneID = existing.focusedPaneID
        selectedTerminalID = existing.selectedTerminalID
        let focusedPaneIDs = Set(existing.panes.filter(\.isFocused).map(\.id))
        let focusedTerminalIDs = Set(existing.terminals.filter(\.isFocused).map(\.id))
        for index in panes.indices {
            panes[index].isFocused = focusedPaneIDs.contains(panes[index].id)
        }
        for index in terminals.indices {
            terminals[index].isFocused = focusedTerminalIDs.contains(terminals[index].id)
        }
    }
}
