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

    /// Removes revisions for one exact aggregate owner key. This intentionally
    /// does not resolve foreground fallbacks because callers are evicting a raw
    /// `workspacesByMac` key that no longer exists.
    func removeWorkspaceFocusRevisions(ownerKey: String) {
        workspaceFocusEventRevisionsByMac[ownerKey] = nil
    }

    /// Re-keys revisions when an anonymous foreground owner adopts its real Mac
    /// identity. A workspace already observed under the destination keeps the
    /// newer revision, and the global monotonic counter is unchanged.
    func moveWorkspaceFocusRevisions(from oldOwnerKey: String, to newOwnerKey: String) {
        guard oldOwnerKey != newOwnerKey,
              let oldRevisions = workspaceFocusEventRevisionsByMac.removeValue(forKey: oldOwnerKey) else {
            return
        }
        var merged = workspaceFocusEventRevisionsByMac[newOwnerKey] ?? [:]
        for (workspaceID, revision) in oldRevisions {
            merged[workspaceID] = max(merged[workspaceID] ?? 0, revision)
        }
        if !merged.isEmpty {
            workspaceFocusEventRevisionsByMac[newOwnerKey] = merged
        }
    }

    /// Drop the previous foreground/anonymous snapshot after a foreground Mac
    /// change. Its focus revisions share the snapshot's raw aggregate owner.
    func dropStalePreviousForeground(_ previousKey: String) {
        guard previousKey != foregroundMacKey,
              secondaryMacSubscriptions[previousKey] == nil else { return }
        let removedWorkspaceIDs = Set((workspacesByMac[previousKey]?.workspaces ?? []).flatMap { workspace in
            let remoteID = workspace.remoteWorkspaceID ?? workspace.id
            return [
                workspace.id.rawValue,
                remoteID.rawValue,
                workspaceAggregation.rowID(macDeviceID: previousKey, workspaceID: remoteID).rawValue,
            ]
        })
        workspacesByMac[previousKey] = nil
        removeWorkspaceFocusRevisions(ownerKey: previousKey)
        for workspaceID in removedWorkspaceIDs {
            chatSessionSnapshotsByWorkspaceID[workspaceID] = nil
        }
    }

    /// Move anonymous foreground state and focus-revision ownership onto a
    /// host-reported stable Mac identity.
    func adoptForegroundMacIdentity(_ macDeviceID: String) {
        guard !macDeviceID.isEmpty, foregroundMacDeviceID != macDeviceID else { return }
        let oldKey = foregroundMacKey
        foregroundMacDeviceID = macDeviceID
        guard oldKey != macDeviceID else { return }
        if var state = workspacesByMac[oldKey] {
            workspacesByMac[oldKey] = nil
            state.macDeviceID = macDeviceID
            state.workspaces = state.workspaces.map { workspace in
                var copy = workspace
                copy.macDeviceID = macDeviceID
                return copy
            }
            workspacesByMac[macDeviceID] = state
        }
        moveWorkspaceFocusRevisions(from: oldKey, to: macDeviceID)
        if let connection = connections[oldKey] {
            connections[oldKey] = nil
            connections[macDeviceID] = connection
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
        applyValidatedFocusSnapshot(
            paneID: event.focusedPaneID.map(MobilePanePreview.ID.init(rawValue:)),
            terminalID: event.selectedTerminalID.map(MobileTerminalPreview.ID.init(rawValue:))
        )
    }

    mutating func preserveFocusSnapshot(from existing: MobileWorkspacePreview) {
        applyValidatedFocusSnapshot(
            paneID: existing.focusedPaneID,
            terminalID: existing.selectedTerminalID
        )
    }

    private mutating func applyValidatedFocusSnapshot(
        paneID: MobilePanePreview.ID?,
        terminalID: MobileTerminalPreview.ID?
    ) {
        switch ValidatedFocusDimension(
            requestedID: paneID,
            isAvailable: { requestedID in panes.contains(where: { $0.id == requestedID }) }
        ) {
        case .clear:
            focusedPaneID = nil
            for index in panes.indices {
                panes[index].isFocused = false
            }
        case .apply(let appliedPaneID):
            focusedPaneID = appliedPaneID
            for index in panes.indices {
                panes[index].isFocused = panes[index].id == appliedPaneID
            }
        case .unchanged:
            break
        }

        switch ValidatedFocusDimension(
            requestedID: terminalID,
            isAvailable: { requestedID in terminals.contains(where: { $0.id == requestedID }) }
        ) {
        case .clear:
            selectedTerminalID = nil
            for index in terminals.indices {
                terminals[index].isFocused = false
            }
        case .apply(let appliedTerminalID):
            selectedTerminalID = appliedTerminalID
            for index in terminals.indices {
                terminals[index].isFocused = terminals[index].id == appliedTerminalID
            }
        case .unchanged:
            break
        }
    }
}

private enum ValidatedFocusDimension<ID: Equatable> {
    case clear
    case apply(ID)
    case unchanged

    init(requestedID: ID?, isAvailable: (ID) -> Bool) {
        guard let requestedID else {
            self = .clear
            return
        }
        if isAvailable(requestedID) {
            self = .apply(requestedID)
        } else {
            self = .unchanged
        }
    }
}
