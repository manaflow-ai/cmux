public import CmuxMobileShellModel
public import Observation

/// Serializes hierarchy mutations and recovery across sheet presentations.
@MainActor
@Observable
public final class MobileTerminalReorderGate {
    private var activeReservationsByOwner: [
        MobileWorkspaceOwnerIdentity: MobileTerminalReorderReservation
    ] = [:]
    private var recoveringOwnerIdentities: Set<MobileWorkspaceOwnerIdentity> = []
    private var refreshRequiredOwnerIdentities: Set<MobileWorkspaceOwnerIdentity> = []
    private var ownerIdentityByPresentationWorkspaceID: [
        MobileWorkspacePreview.ID: MobileWorkspaceOwnerIdentity
    ] = [:]
    private var currentPresentationWorkspaceIDByOwner: [
        MobileWorkspaceOwnerIdentity: MobileWorkspacePreview.ID
    ] = [:]
    private var lastPresentationWorkspaceIDByOwner: [
        MobileWorkspaceOwnerIdentity: MobileWorkspacePreview.ID
    ] = [:]

    /// Workspaces whose acknowledged mutations still need authoritative recovery.
    /// IDs are current presentation payloads; lifecycle state is owner-keyed.
    public var refreshRequiredWorkspaceIDs: Set<MobileWorkspacePreview.ID> {
        Set(refreshRequiredOwnerIdentities.map { ownerIdentity in
            currentPresentationWorkspaceIDByOwner[ownerIdentity]
                ?? lastPresentationWorkspaceIDByOwner[ownerIdentity]
                ?? ownerIdentity.rpcWorkspaceID
        })
    }

    /// Creates an inactive reorder gate.
    public init() {}

    /// Whether any workspace currently owns a hierarchy mutation or recovery.
    public var isActive: Bool {
        !activeReservationsByOwner.isEmpty || !recoveringOwnerIdentities.isEmpty
    }

    /// Whether one workspace currently owns a hierarchy mutation or recovery.
    public func isActive(workspaceID: MobileWorkspacePreview.ID) -> Bool {
        let ownerIdentity = workspaceOwnerIdentity(for: workspaceID)
        return activeReservationsByOwner[ownerIdentity] != nil
            || recoveringOwnerIdentities.contains(ownerIdentity)
    }

    /// Whether a new close or reorder may start in one workspace.
    public func canMutate(workspaceID: MobileWorkspacePreview.ID) -> Bool {
        let ownerIdentity = workspaceOwnerIdentity(for: workspaceID)
        return activeReservationsByOwner[ownerIdentity] == nil
            && !recoveringOwnerIdentities.contains(ownerIdentity)
            && !refreshRequiredOwnerIdentities.contains(ownerIdentity)
    }

    /// Whether one workspace is waiting for authoritative recovery.
    public func requiresRefresh(workspaceID: MobileWorkspacePreview.ID) -> Bool {
        refreshRequiredOwnerIdentities.contains(workspaceOwnerIdentity(for: workspaceID))
    }

    /// Claims the reorder owner before optimistic UI changes are applied.
    public func reserve(
        workspaceID: MobileWorkspacePreview.ID,
        paneID: MobilePanePreview.ID
    ) -> MobileTerminalReorderReservation? {
        let ownerIdentity = rememberWorkspaceOwnerIdentity(for: workspaceID)
        guard activeReservationsByOwner[ownerIdentity] == nil,
              !recoveringOwnerIdentities.contains(ownerIdentity),
              !refreshRequiredOwnerIdentities.contains(ownerIdentity) else { return nil }
        let reservation = MobileTerminalReorderReservation(
            ownerIdentity: ownerIdentity,
            workspaceID: workspaceID,
            paneID: paneID
        )
        activeReservationsByOwner[ownerIdentity] = reservation
        return reservation
    }

    /// Releases the owner only for the matching reorder operation.
    public func finish(_ reservation: MobileTerminalReorderReservation) {
        guard activeReservationsByOwner[reservation.ownerIdentity] == reservation else { return }
        activeReservationsByOwner[reservation.ownerIdentity] = nil
        prunePresentationAliases()
    }

    /// Keeps hierarchy mutations disabled until an authoritative reload succeeds.
    public func requireRefresh(workspaceID: MobileWorkspacePreview.ID) {
        refreshRequiredOwnerIdentities.insert(rememberWorkspaceOwnerIdentity(for: workspaceID))
    }

    /// Claims one workspace's recovery owner after an acknowledged mutation.
    public func beginRecovery(workspaceID: MobileWorkspacePreview.ID) -> Bool {
        let ownerIdentity = rememberWorkspaceOwnerIdentity(for: workspaceID)
        guard refreshRequiredOwnerIdentities.contains(ownerIdentity),
              activeReservationsByOwner[ownerIdentity] == nil,
              !recoveringOwnerIdentities.contains(ownerIdentity) else { return false }
        recoveringOwnerIdentities.insert(ownerIdentity)
        return true
    }

    /// Completes recovery, preserving the dirty state after another failure.
    public func finishRecovery(workspaceID: MobileWorkspacePreview.ID, succeeded: Bool) {
        let ownerIdentity = workspaceOwnerIdentity(for: workspaceID)
        guard recoveringOwnerIdentities.remove(ownerIdentity) != nil else { return }
        if succeeded {
            refreshRequiredOwnerIdentities.remove(ownerIdentity)
        }
        prunePresentationAliases()
    }

    /// Reopens workspaces represented by a successful authoritative list read.
    /// Callers include prior IDs so remotely removed rows cannot leave stale state.
    func reconcileAfterAuthoritativeRefresh(
        workspaceIDs: Set<MobileWorkspacePreview.ID>
    ) {
        refreshRequiredOwnerIdentities.subtract(workspaceIDs.map(workspaceOwnerIdentity(for:)))
        prunePresentationAliases()
    }

    func owns(_ reservation: MobileTerminalReorderReservation) -> Bool {
        activeReservationsByOwner[reservation.ownerIdentity] == reservation
    }

    /// Rebinds presentation rows after one-Mac/multi-Mac aggregation changes IDs.
    /// State remains keyed by owner identity; old row aliases survive only while
    /// that owner is still visible or has an active/fenced lifecycle.
    func updateWorkspacePresentationIdentities(_ workspaces: [MobileWorkspacePreview]) {
        currentPresentationWorkspaceIDByOwner = Dictionary(
            workspaces.map { workspace in
                (MobileWorkspaceOwnerIdentity(workspace: workspace), workspace.id)
            },
            uniquingKeysWith: { current, _ in current }
        )
        for workspace in workspaces {
            let ownerIdentity = MobileWorkspaceOwnerIdentity(workspace: workspace)
            ownerIdentityByPresentationWorkspaceID[workspace.id] = ownerIdentity
            lastPresentationWorkspaceIDByOwner[ownerIdentity] = workspace.id
        }
        prunePresentationAliases()
    }

    private func workspaceOwnerIdentity(
        for workspaceID: MobileWorkspacePreview.ID
    ) -> MobileWorkspaceOwnerIdentity {
        ownerIdentityByPresentationWorkspaceID[workspaceID]
            ?? MobileWorkspaceOwnerIdentity(fallbackPresentationID: workspaceID)
    }

    private func rememberWorkspaceOwnerIdentity(
        for workspaceID: MobileWorkspacePreview.ID
    ) -> MobileWorkspaceOwnerIdentity {
        let ownerIdentity = workspaceOwnerIdentity(for: workspaceID)
        ownerIdentityByPresentationWorkspaceID[workspaceID] = ownerIdentity
        if currentPresentationWorkspaceIDByOwner[ownerIdentity] == nil {
            lastPresentationWorkspaceIDByOwner[ownerIdentity] = workspaceID
        }
        return ownerIdentity
    }

    private func prunePresentationAliases() {
        let retainedOwnerIdentities = Set(currentPresentationWorkspaceIDByOwner.keys)
            .union(activeReservationsByOwner.keys)
            .union(recoveringOwnerIdentities)
            .union(refreshRequiredOwnerIdentities)
        ownerIdentityByPresentationWorkspaceID = ownerIdentityByPresentationWorkspaceID.filter {
            retainedOwnerIdentities.contains($0.value)
        }
        lastPresentationWorkspaceIDByOwner = lastPresentationWorkspaceIDByOwner.filter {
            retainedOwnerIdentities.contains($0.key)
        }
    }
}
