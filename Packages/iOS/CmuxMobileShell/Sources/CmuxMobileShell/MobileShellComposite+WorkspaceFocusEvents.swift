internal import CmuxMobileRPC
internal import CmuxMobileShellModel

struct MobileWorkspaceFocusDimensionRevisions: Equatable, Sendable {
    var pane: UInt64 = 0
    var terminal: UInt64 = 0

    mutating func record(_ dimensions: MobileWorkspaceFocusAppliedDimensions, at revision: UInt64) {
        if dimensions.pane { pane = revision }
        if dimensions.terminal { terminal = revision }
    }

    func maxMerged(with other: Self) -> Self {
        Self(pane: max(pane, other.pane), terminal: max(terminal, other.terminal))
    }
}

extension MobileShellComposite {
    /// Applies a focus-only event without fetching or decoding the full list.
    func applyWorkspaceFocusEvent(_ event: MobileWorkspaceFocusEvent, macID: String?) {
        // State may still live under the anonymous foreground key while an
        // active ticket already exposes the Mac's durable identity. Keep the
        // existing state lookup during that promotion window; only the ordering
        // ledger resolves through the durable focus owner.
        let stateOwnerKey = macID ?? foregroundMacKey
        let sequenceOwnerKey = workspaceFocusOwnerKey(macID: macID)
        guard var state = workspacesByMac[stateOwnerKey],
              let sourceIndex = state.workspaces.firstIndex(where: {
                  $0.rpcWorkspaceID.rawValue == event.workspaceID
              }) else { return }
        guard claimWorkspaceFocusHostSequence(event, ownerKey: sequenceOwnerKey) else { return }
        var sourceWorkspace = state.workspaces[sourceIndex]
        let dimensions = sourceWorkspace.applyFocusSnapshot(event)
        guard !dimensions.isEmpty else { return }

        let remoteWorkspaceID = sourceWorkspace.remoteWorkspaceID ?? sourceWorkspace.id
        let ownerID = sourceWorkspace.macDeviceID ?? state.macDeviceID
        let visibleWorkspaceID = workspacesByMac.keys.filter { !$0.isEmpty }.count > 1
            && !ownerID.isEmpty
            ? workspaceAggregation.rowID(macDeviceID: ownerID, workspaceID: remoteWorkspaceID)
            : sourceWorkspace.id
        guard let visibleIndex = workspaces.firstIndex(where: { $0.id == visibleWorkspaceID }) else {
            return
        }

        state.workspaces[sourceIndex] = sourceWorkspace
        replaceWorkspaceSourceFocus(for: stateOwnerKey, with: state)

        var visibleWorkspace = workspaces[visibleIndex]
        _ = visibleWorkspace.applyFocusSnapshot(event)
        replaceVisibleWorkspaceFocus(at: visibleIndex, with: visibleWorkspace)

        recordWorkspaceFocusEvent(event, dimensions: dimensions, macID: macID)
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
        let revisions = workspaceFocusEventRevisionsByMac[ownerKey]?[workspace.rpcWorkspaceID.rawValue]
            ?? MobileWorkspaceFocusDimensionRevisions()
        let dimensions = MobileWorkspaceFocusAppliedDimensions(
            pane: revisions.pane > listStartedAtFocusRevision,
            terminal: revisions.terminal > listStartedAtFocusRevision
        )
        guard !dimensions.isEmpty else { return }
        workspace.preserveFocusSnapshot(from: existingWorkspace, dimensions: dimensions)
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
        workspaceFocusHostSequencesByMac[ownerKey] = nil
    }

    /// Re-keys revisions when an anonymous foreground owner adopts its real Mac
    /// identity. A workspace already observed under the destination keeps the
    /// newer revision, and the global monotonic counter is unchanged.
    func moveWorkspaceFocusRevisions(from oldOwnerKey: String, to newOwnerKey: String) {
        guard oldOwnerKey != newOwnerKey else { return }
        if let oldRevisions = workspaceFocusEventRevisionsByMac.removeValue(forKey: oldOwnerKey) {
            var merged = workspaceFocusEventRevisionsByMac[newOwnerKey] ?? [:]
            for (workspaceID, revisions) in oldRevisions {
                merged[workspaceID] = (merged[workspaceID] ?? .init()).maxMerged(with: revisions)
            }
            if !merged.isEmpty {
                workspaceFocusEventRevisionsByMac[newOwnerKey] = merged
            }
        }
        if let oldHostSequences = workspaceFocusHostSequencesByMac.removeValue(forKey: oldOwnerKey) {
            var mergedHostSequences = workspaceFocusHostSequencesByMac[newOwnerKey] ?? [:]
            for (workspaceID, sequence) in oldHostSequences {
                mergedHostSequences[workspaceID] = max(mergedHostSequences[workspaceID] ?? 0, sequence)
            }
            if !mergedHostSequences.isEmpty {
                workspaceFocusHostSequencesByMac[newOwnerKey] = mergedHostSequences
            }
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
        dimensions: MobileWorkspaceFocusAppliedDimensions,
        macID: String?
    ) {
        guard !dimensions.isEmpty else { return }
        workspaceFocusEventRevision &+= 1
        let ownerKey = workspaceFocusOwnerKey(macID: macID)
        workspaceFocusEventRevisionsByMac[ownerKey, default: [:]][event.workspaceID, default: .init()]
            .record(dimensions, at: workspaceFocusEventRevision)
    }

    /// Claims a host ordering token before mutating focus. Once a modern host
    /// supplies a token for a workspace, lower/equal tokens and unsequenced
    /// envelopes cannot rewind it. A legacy host remains fully compatible
    /// because its new connection never establishes a high-water mark.
    private func claimWorkspaceFocusHostSequence(
        _ event: MobileWorkspaceFocusEvent,
        ownerKey: String
    ) -> Bool {
        let lastSequence = workspaceFocusHostSequencesByMac[ownerKey]?[event.workspaceID]
        guard let sequence = event.sequence else {
            return lastSequence == nil
        }
        guard lastSequence.map({ sequence > $0 }) ?? true else { return false }
        workspaceFocusHostSequencesByMac[ownerKey, default: [:]][event.workspaceID] = sequence
        return true
    }

    /// A host process may restart its counter at zero. Clear only the owner
    /// whose transport was replaced; other live Mac streams keep their guards.
    func resetWorkspaceFocusHostSequenceTracking(ownerKey: String) {
        guard !ownerKey.isEmpty else { return }
        workspaceFocusHostSequencesByMac[ownerKey] = nil
    }

    func resetWorkspaceFocusHostSequenceTracking(macID: String?) {
        resetWorkspaceFocusHostSequenceTracking(ownerKey: workspaceFocusOwnerKey(macID: macID))
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
