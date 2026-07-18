import CmuxTerminalBackend
import Foundation

/// Process-reconnecting seam for daemon-retained Swift window placement.
protocol TerminalBackendProjectionStateServing: Sendable {
    func claimProjectionState(
        logicalPresentationID: UUID
    ) async throws -> BackendProjectionState
    func updateProjectionStates(
        _ projections: [BackendProjectionStateUpdate]
    ) async throws -> [BackendProjectionState]
    func releaseProjectionState(
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64
    ) async throws
    func listProjectionStates() async throws -> [BackendProjectionState]
}

/// A prevalidated, synchronous window-ownership update for one live workspace.
@MainActor
final class TerminalBackendTopologyWorkspaceOwnershipTransfer {
    private enum State {
        case prepared
        case committed
        case rolledBack
    }

    private let commitOperation: @MainActor () throws -> Void
    private let rollbackOperation: @MainActor () -> Void
    private var state = State.prepared

    init(
        commit: @escaping @MainActor () throws -> Void,
        rollback: @escaping @MainActor () -> Void
    ) {
        commitOperation = commit
        rollbackOperation = rollback
    }

    func commit() throws {
        guard state == .prepared else { return }
        try commitOperation()
        state = .committed
    }

    func rollback() {
        guard state == .committed else { return }
        rollbackOperation()
        state = .rolledBack
    }
}

struct TerminalBackendTopologyWorkspaceOwnerReservation: Equatable, Sendable {
    let workspaceID: UUID
    let presentationID: UUID
    let token: UUID
}

struct TerminalBackendEmptyTopologyBootstrapClaim: Equatable, Sendable {
    let authority: BackendAuthority
    let presentationID: UUID
    let token: UUID
}

/// Process-wide presentation graph for daemon-owned terminal topology.
///
/// Canonical workspaces remain owned by cmuxd. This sidecar records only which
/// Swift window presents each workspace, so one backend workspace is never
/// projected into two independent `TabManager` graphs by accident.
@MainActor
final class TerminalBackendTopologyProjectionRegistry: TerminalBackendTopologyProjecting {
    private struct ScreenSelectionKey: Hashable {
        let presentationID: UUID
        let workspaceID: UUID
    }
    private final class Entry {
        let presentationID: UUID
        weak var projector: (any TerminalBackendTopologyProjecting)?

        init(
            presentationID: UUID,
            projector: any TerminalBackendTopologyProjecting
        ) {
            self.presentationID = presentationID
            self.projector = projector
        }
    }

    private var entries: [UUID: Entry] = [:]
    private var registrationOrder: [UUID] = []
    private var primaryPresentationID: UUID?

    /// Swift-owned window placement. Entries intentionally survive a window
    /// close so closing one presentation does not make its persistent backend
    /// workspaces jump into another window.
    private var workspaceOwners: [UUID: UUID] = [:]
    private var pendingWorkspaceOwnerReservations: [
        UUID: TerminalBackendTopologyWorkspaceOwnerReservation
    ] = [:]
    private var emptyTopologyBootstrapClaim: TerminalBackendEmptyTopologyBootstrapClaim?
    private var selectedScreens: [ScreenSelectionKey: UUID] = [:]

    private let projectionStateStore: (any TerminalBackendProjectionStateServing)?
    private var projectionStateClaims: [UUID: BackendProjectionState] = [:]
    private var projectionStateHydrationStarted = false
    private var projectionStateHydrationGeneration: UInt64 = 0
    private var projectionStateHydrationTask: Task<Void, Never>?
    private var projectionStatePersistenceGeneration: UInt64 = 0
    private var projectionStatePersistenceTask: Task<Void, Never>?
    private var projectionStateDidChange: (@MainActor () -> Void)?
    private var projectionStateHydrated = false
    private var pendingProjectionReleases: Set<UUID> = []
    private var projectionReleaseTasks: [UUID: Task<Void, Never>] = [:]

    init(
        projectionStateStore: (any TerminalBackendProjectionStateServing)? = nil
    ) {
        self.projectionStateStore = projectionStateStore
    }

    deinit {
        projectionStateHydrationTask?.cancel()
        projectionStatePersistenceTask?.cancel()
        for task in projectionReleaseTasks.values {
            task.cancel()
        }
    }

    func setProjectionStateDidChange(
        _ operation: @escaping @MainActor () -> Void
    ) {
        projectionStateDidChange = operation
        if projectionStateStore == nil || projectionStateIsReady {
            operation()
        }
    }

    /// Seals the app's session-restored window set before daemon placement is
    /// allowed to influence the first canonical projection.
    func startupRestoreDidFinish() {
        guard projectionStateStore != nil else { return }
        projectionStateHydrationStarted = true
        beginProjectionStateHydration()
    }

    @discardableResult
    func register(
        _ projector: any TerminalBackendTopologyProjecting,
        presentationID: UUID,
        isPrimary: Bool
    ) -> Bool {
        purgeDeadEntries()
        if entries[presentationID]?.projector === projector,
           (primaryPresentationID == presentationID) == isPrimary,
           !entries.contains(where: { id, entry in
               id != presentationID && entry.projector === projector
           }) {
            return false
        }
        removeEntries(for: projector)
        entries[presentationID] = Entry(
            presentationID: presentationID,
            projector: projector
        )
        registrationOrder.removeAll { $0 == presentationID }
        registrationOrder.append(presentationID)
        if let tabManager = projector as? TabManager {
            tabManager.terminalBackendTopologyProjectionRegistry = self
            tabManager.terminalBackendProjectionPresentationID = presentationID
        }
        if isPrimary || primaryPresentationID == nil {
            primaryPresentationID = presentationID
        } else if primaryPresentationID == presentationID {
            primaryPresentationID = registrationOrder.first(where: { $0 != presentationID })
        }
        purgeDeadEntries()
        if projectionStateStore != nil, projectionStateHydrationStarted {
            beginProjectionStateHydration()
        }
        return true
    }

    func unregister(_ projector: any TerminalBackendTopologyProjecting) {
        removeEntries(for: projector)
        purgeDeadEntries()
        if projectionStateStore != nil, projectionStateHydrationStarted {
            beginProjectionStateHydration()
        }
    }

    func reserveWorkspaceOwner(
        workspaceID: UUID,
        for projector: any TerminalBackendTopologyProjecting
    ) throws -> TerminalBackendTopologyWorkspaceOwnerReservation {
        purgeDeadEntries()
        guard let presentationID = liveEntries().first(where: {
            $0.projector === projector
        })?.presentationID else {
            throw TerminalBackendTopologyProjectionError.projectionFailed(
                "workspace creation references an unregistered presentation"
            )
        }
        guard workspaceOwners[workspaceID] == nil,
              pendingWorkspaceOwnerReservations[workspaceID] == nil else {
            throw TerminalBackendTopologyProjectionError.projectionFailed(
                "workspace creation identity already has a presentation owner"
            )
        }
        let reservation = TerminalBackendTopologyWorkspaceOwnerReservation(
            workspaceID: workspaceID,
            presentationID: presentationID,
            token: UUID()
        )
        pendingWorkspaceOwnerReservations[workspaceID] = reservation
        return reservation
    }

    func cancelWorkspaceOwnerReservation(
        _ reservation: TerminalBackendTopologyWorkspaceOwnerReservation
    ) {
        guard pendingWorkspaceOwnerReservations[reservation.workspaceID] == reservation else {
            return
        }
        pendingWorkspaceOwnerReservations.removeValue(forKey: reservation.workspaceID)
    }

    func claimEmptyTopologyBootstrap(
        authority: BackendAuthority,
        for projector: any TerminalBackendTopologyProjecting
    ) -> TerminalBackendEmptyTopologyBootstrapClaim? {
        purgeDeadEntries()
        guard let presentationID = liveEntries().first(where: {
            $0.projector === projector
        })?.presentationID else { return nil }
        if let claim = emptyTopologyBootstrapClaim {
            guard claim.authority != authority else { return nil }
            emptyTopologyBootstrapClaim = nil
        }
        let claim = TerminalBackendEmptyTopologyBootstrapClaim(
            authority: authority,
            presentationID: presentationID,
            token: UUID()
        )
        emptyTopologyBootstrapClaim = claim
        return claim
    }

    func releaseEmptyTopologyBootstrap(
        _ claim: TerminalBackendEmptyTopologyBootstrapClaim
    ) {
        guard emptyTopologyBootstrapClaim == claim else { return }
        emptyTopologyBootstrapClaim = nil
        projectionStateDidChange?()
    }

    /// Deletes backend placement only for a user-confirmed AppKit window close.
    /// Generic unregister and app teardown retain it for process restart.
    func closeProjection(presentationID: UUID) {
        guard projectionStateStore != nil,
              let claim = projectionStateClaims[presentationID],
              claim.claimID != nil else {
            return
        }
        projectionStateClaims.removeValue(forKey: presentationID)
        projectionStateHydrated = false
        pendingProjectionReleases.insert(presentationID)
        workspaceOwners = workspaceOwners.filter { $0.value != presentationID }
        selectedScreens = selectedScreens.filter { $0.key.presentationID != presentationID }
        projectionStateHydrationGeneration &+= 1
        projectionStateHydrationTask?.cancel()
        projectionStateHydrationTask = nil
        projectionStatePersistenceGeneration &+= 1
        projectionStatePersistenceTask?.cancel()
        projectionStatePersistenceTask = nil
        beginProjectionRelease(presentationID, initialClaim: claim)
    }

    private func beginProjectionRelease(
        _ presentationID: UUID,
        initialClaim: BackendProjectionState?
    ) {
        guard let projectionStateStore,
              pendingProjectionReleases.contains(presentationID),
              projectionReleaseTasks[presentationID] == nil else {
            return
        }
        projectionReleaseTasks[presentationID] = Task { [weak self] in
            do {
                if let initialClaim,
                   let claimID = initialClaim.claimID {
                    try await projectionStateStore.releaseProjectionState(
                        logicalPresentationID: presentationID,
                        claimID: claimID,
                        expectedGeneration: initialClaim.generation
                    )
                } else {
                    try await Self.reclaimAndReleaseProjection(
                        presentationID,
                        store: projectionStateStore
                    )
                }
                try Task.checkCancellation()
                self?.projectionReleaseDidFinish(presentationID)
            } catch is CancellationError {
                return
            } catch {
                do {
                    try await Self.reclaimAndReleaseProjection(
                        presentationID,
                        store: projectionStateStore
                    )
                    try Task.checkCancellation()
                    self?.projectionReleaseDidFinish(presentationID)
                } catch is CancellationError {
                    return
                } catch {
                    self?.projectionReleaseAttemptDidFail(presentationID)
                }
            }
        }
    }

    private nonisolated static func reclaimAndReleaseProjection(
        _ presentationID: UUID,
        store: any TerminalBackendProjectionStateServing
    ) async throws {
        let reclaimed = try await store.claimProjectionState(
            logicalPresentationID: presentationID
        )
        guard let claimID = reclaimed.claimID else {
            throw TerminalBackendTopologyProjectionError.projectionFailed(
                "daemon did not return a projection-state claim"
            )
        }
        try await store.releaseProjectionState(
            logicalPresentationID: presentationID,
            claimID: claimID,
            expectedGeneration: reclaimed.generation
        )
    }

    /// Preflights a user-driven move of one entire Workspace object between
    /// windows. The caller commits this prevalidated ownership fence before a
    /// synchronous detach/attach of the same object, so rejection cannot leak
    /// local layout side effects and no renderer restart is required.
    func prepareWorkspaceOwnershipTransfer(
        workspaceID: UUID,
        from source: any TerminalBackendTopologyProjecting,
        to destination: any TerminalBackendTopologyProjecting
    ) throws -> TerminalBackendTopologyWorkspaceOwnershipTransfer {
        purgeDeadEntries()
        guard let sourcePresentationID = liveEntries().first(where: {
            $0.projector === source
        })?.presentationID,
        let destinationPresentationID = liveEntries().first(where: {
            $0.projector === destination
        })?.presentationID else {
            throw TerminalBackendTopologyProjectionError.projectionFailed(
                "workspace window move references an unregistered presentation"
            )
        }
        let previousOwner = workspaceOwners[workspaceID]
        guard previousOwner == nil || previousOwner == sourcePresentationID else {
            throw TerminalBackendTopologyProjectionError.projectionFailed(
                "workspace window move source does not own the presentation"
            )
        }

        return TerminalBackendTopologyWorkspaceOwnershipTransfer(
            commit: { [weak self, weak source, weak destination] in
                guard let self, let source, let destination,
                      self.entries[sourcePresentationID]?.projector === source,
                      self.entries[destinationPresentationID]?.projector === destination,
                      self.workspaceOwners[workspaceID] == previousOwner else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "workspace window ownership changed during transfer"
                    )
                }
                self.workspaceOwners[workspaceID] = destinationPresentationID
                let sourceKey = ScreenSelectionKey(
                    presentationID: sourcePresentationID,
                    workspaceID: workspaceID
                )
                if let selectedScreen = self.selectedScreens.removeValue(forKey: sourceKey) {
                    self.selectedScreens[ScreenSelectionKey(
                        presentationID: destinationPresentationID,
                        workspaceID: workspaceID
                    )] = selectedScreen
                }
            },
            rollback: { [weak self] in
                guard let self,
                      self.workspaceOwners[workspaceID] == destinationPresentationID else {
                    return
                }
                self.workspaceOwners[workspaceID] = previousOwner
                let destinationKey = ScreenSelectionKey(
                    presentationID: destinationPresentationID,
                    workspaceID: workspaceID
                )
                if let selectedScreen = self.selectedScreens.removeValue(forKey: destinationKey) {
                    self.selectedScreens[ScreenSelectionKey(
                        presentationID: sourcePresentationID,
                        workspaceID: workspaceID
                    )] = selectedScreen
                }
            }
        )
    }

    func resolvePresentationPlan(
        _ plan: TerminalBackendTopologyProjectionPlan
    ) throws -> TerminalBackendTopologyProjectionPlan {
        purgeDeadEntries()
        try requireProjectionStateReady()
        let live = liveEntries()
        var placementsByPresentation: [UUID: Set<TerminalBackendTopologyPlacement>] = [:]
        var surfaceIDsByPresentation: [UUID: Set<UUID>] = [:]
        var workspaceOwnersFromSwift: [UUID: Set<UUID>] = [:]
        var surfaceOwners: [UUID: Set<UUID>] = [:]
        for entry in live {
            guard let projector = entry.projector else { continue }
            let placements = projector.allPresentationPlacements()
            placementsByPresentation[entry.presentationID] = placements
            surfaceIDsByPresentation[entry.presentationID] = Set(placements.map(\.surfaceID))
            for workspaceID in projector.presentationWorkspaceIDs() {
                workspaceOwnersFromSwift[workspaceID, default: []].insert(entry.presentationID)
            }
            for placement in placements {
                surfaceOwners[placement.surfaceID, default: []].insert(entry.presentationID)
            }
        }

        var selectedByWorkspace: [UUID: UUID] = [:]
        for workspace in plan.workspaces {
            let workspaceID = workspace.canonical.uuid.rawValue
            let exactOwners = workspaceOwnersFromSwift[workspaceID] ?? []
            guard exactOwners.count <= 1 else {
                throw TerminalBackendTopologyProjectionError.projectionFailed(
                    "canonical workspace appears in multiple Swift presentations"
                )
            }
            let allSurfaceIDs = workspace.allCanonicalSurfaceIDs
            let matchingOwners = allSurfaceIDs.reduce(into: Set<UUID>()) { owners, surfaceID in
                owners.formUnion(surfaceOwners[surfaceID] ?? [])
            }
            let owner = workspaceOwners[workspaceID]
                ?? pendingWorkspaceOwnerReservations[workspaceID]?.presentationID
                ?? exactOwners.first
                ?? (matchingOwners.count == 1 ? matchingOwners.first : nil)
                ?? primaryPresentationID
            guard let owner else { continue }
            let presentedSurfaceIDs = surfaceIDsByPresentation[owner] ?? []
            let matchingScreens = workspace.screens.filter { screen in
                screen.panes.contains { pane in
                    pane.tabs.contains { presentedSurfaceIDs.contains($0.uuid.rawValue) }
                }
            }
            guard matchingScreens.count <= 1 else {
                throw TerminalBackendTopologyProjectionError.projectionFailed(
                    "one Swift presentation materializes multiple backend screens"
                )
            }
            let key = ScreenSelectionKey(
                presentationID: owner,
                workspaceID: workspaceID
            )
            let selected = matchingScreens.first?.uuid.rawValue
                ?? selectedScreens[key].flatMap { retained in
                    workspace.screens.contains(where: { $0.uuid.rawValue == retained })
                        ? retained
                        : nil
                }
                ?? workspace.screens.first?.uuid.rawValue
            if let selected {
                selectedScreens[key] = selected
                selectedByWorkspace[workspaceID] = selected
            }
        }
        return try plan.selectingScreens(selectedByWorkspace)
    }

    func presentationWorkspaceIDs() -> Set<UUID> {
        purgeDeadEntries()
        return liveEntries().reduce(into: Set<UUID>()) { workspaceIDs, entry in
            guard let projector = entry.projector else { return }
            workspaceIDs.formUnion(projector.presentationWorkspaceIDs())
        }
    }

    func legacyTerminalPlacements() -> Set<TerminalBackendTopologyPlacement> {
        purgeDeadEntries()
        return liveEntries().reduce(
            into: Set<TerminalBackendTopologyPlacement>()
        ) { placements, entry in
            guard let projector = entry.projector else { return }
            placements.formUnion(projector.legacyTerminalPlacements())
        }
    }

    func frontendNativeBrowserSourceURL(surfaceID: SurfaceID) -> URL? {
        purgeDeadEntries()
        return liveEntries().lazy.compactMap { entry in
            entry.projector?.frontendNativeBrowserSourceURL(surfaceID: surfaceID)
        }.first
    }

    func frontendNativeBrowserIsPresented(surfaceID: SurfaceID) -> Bool {
        purgeDeadEntries()
        return liveEntries().contains { entry in
            entry.projector?.frontendNativeBrowserIsPresented(surfaceID: surfaceID)
                == true
        }
    }

    func installFrontendNativeBrowserClaimSourceURL(
        _ sourceURL: URL,
        surfaceID: SurfaceID
    ) {
        purgeDeadEntries()
        for entry in liveEntries() {
            entry.projector?.installFrontendNativeBrowserClaimSourceURL(
                sourceURL,
                surfaceID: surfaceID
            )
        }
    }

    func prepareCanonicalTopology(
        _ snapshot: TopologySnapshot,
        plan: TerminalBackendTopologyProjectionPlan
    ) throws -> TerminalBackendTopologyPreparedProjection {
        purgeDeadEntries()
        try requireProjectionStateReady()
        let live = liveEntries()
        guard !live.isEmpty || plan.workspaces.isEmpty else {
            throw TerminalBackendTopologyProjectionError.projectionFailed(
                "canonical topology has no registered Swift presentation"
            )
        }

        var surfaceOwners: [UUID: Set<UUID>] = [:]
        var workspaceOwnersFromSwift: [UUID: Set<UUID>] = [:]
        for entry in live {
            guard let projector = entry.projector else { continue }
            let placements = projector.allPresentationPlacements()
            for workspaceID in projector.presentationWorkspaceIDs() {
                workspaceOwnersFromSwift[workspaceID, default: []]
                    .insert(entry.presentationID)
            }
            for placement in placements {
                surfaceOwners[placement.surfaceID, default: []].insert(entry.presentationID)
            }
        }

        let previousWorkspaceOwners = workspaceOwners
        let previousOwnerReservations = pendingWorkspaceOwnerReservations
        let previousBootstrapClaim = emptyTopologyBootstrapClaim
        if let claim = emptyTopologyBootstrapClaim,
           claim.authority != snapshot.authority || !plan.workspaces.isEmpty {
            emptyTopologyBootstrapClaim = nil
        }
        let canonicalWorkspaceIDs = Set(plan.workspaces.map { $0.canonical.uuid.rawValue })
        var candidateWorkspaceOwners = workspaceOwners.filter {
            canonicalWorkspaceIDs.contains($0.key)
        }

        for workspacePlan in plan.workspaces {
            let workspaceID = workspacePlan.canonical.uuid.rawValue
            let exactOwners = workspaceOwnersFromSwift[workspaceID] ?? []
            if exactOwners.count > 1 {
                throw TerminalBackendTopologyProjectionError.projectionFailed(
                    "canonical workspace appears in multiple Swift presentations"
                )
            }
            if let recordedOwner = candidateWorkspaceOwners[workspaceID] {
                if let exactOwner = exactOwners.first, exactOwner != recordedOwner {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "canonical workspace presentation moved without an ownership transfer"
                    )
                }
                continue
            }

            if let reservation = pendingWorkspaceOwnerReservations[workspaceID] {
                guard entries[reservation.presentationID]?.projector != nil else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "reserved workspace presentation is no longer registered"
                    )
                }
                candidateWorkspaceOwners[workspaceID] = reservation.presentationID
                continue
            }

            let matchingSurfaceOwners = workspacePlan.allCanonicalSurfaceIDs.reduce(
                into: Set<UUID>()
            ) {
                owners, surfaceID in
                owners.formUnion(surfaceOwners[surfaceID] ?? [])
            }
            let candidates = !exactOwners.isEmpty ? exactOwners : matchingSurfaceOwners
            if candidates.count > 1 {
                throw TerminalBackendTopologyProjectionError.projectionFailed(
                    "canonical workspace surfaces appear in multiple Swift presentations"
                )
            }
            if let existing = candidates.first {
                candidateWorkspaceOwners[workspaceID] = existing
            } else if let primaryPresentationID {
                candidateWorkspaceOwners[workspaceID] = primaryPresentationID
            }
        }

        // Cross-window panel moves need an explicit process-wide transfer
        // transaction. Until that transaction exists, fail closed before any
        // child mutates instead of replacing a live TerminalPanel/BrowserPanel
        // with a fresh object in the destination window.
        for workspacePlan in plan.workspaces {
            let workspaceID = workspacePlan.canonical.uuid.rawValue
            guard let targetOwner = candidateWorkspaceOwners[workspaceID] else { continue }
            let presentedSurfaceIDs = workspacePlan.screen.panes.flatMap { pane in
                pane.tabs.map { $0.uuid.rawValue }
            }
            for surfaceID in presentedSurfaceIDs {
                let displacedOwners = (surfaceOwners[surfaceID] ?? [])
                    .subtracting([targetOwner])
                guard displacedOwners.isEmpty else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "canonical surface move crosses Swift window presentations"
                    )
                }
            }
        }

        var workspaceIDsByOwner: [UUID: Set<UUID>] = [:]
        workspaceIDsByOwner.reserveCapacity(live.count)
        for (workspaceID, owner) in candidateWorkspaceOwners {
            workspaceIDsByOwner[owner, default: []].insert(workspaceID)
        }

        var preparedChildren: [TerminalBackendTopologyPreparedProjection] = []
        preparedChildren.reserveCapacity(live.count)
        for entry in live {
            guard let projector = entry.projector else { continue }
            let workspaceIDs = workspaceIDsByOwner[entry.presentationID] ?? []
            preparedChildren.append(try projector.prepareCanonicalTopology(
                snapshot,
                plan: try plan.selectingWorkspaces(workspaceIDs)
            ))
        }

        return TerminalBackendTopologyPreparedProjection(
            commit: { [weak self] in
                for child in preparedChildren {
                    try child.commit()
                }
                self?.workspaceOwners = candidateWorkspaceOwners
                if let self {
                    let committedReservationWorkspaceIDs = self
                        .pendingWorkspaceOwnerReservations
                        .compactMap { workspaceID, reservation in
                            candidateWorkspaceOwners[workspaceID] == reservation.presentationID
                                ? workspaceID
                                : nil
                        }
                    for workspaceID in committedReservationWorkspaceIDs {
                        self.pendingWorkspaceOwnerReservations.removeValue(forKey: workspaceID)
                    }
                }
            },
            finalize: {
                for child in preparedChildren {
                    child.finalize()
                }
                self.persistProjectionStateIfNeeded()
            },
            rollback: { [weak self] in
                var firstRollbackError: (any Error)?
                for child in preparedChildren.reversed() {
                    do {
                        try child.rollback()
                    } catch {
                        if firstRollbackError == nil {
                            firstRollbackError = error
                        }
                    }
                }
                self?.workspaceOwners = previousWorkspaceOwners
                self?.pendingWorkspaceOwnerReservations = previousOwnerReservations
                self?.emptyTopologyBootstrapClaim = previousBootstrapClaim
                if let firstRollbackError {
                    throw firstRollbackError
                }
            }
        )
    }

    #if DEBUG
    func debugWorkspaceOwner(_ workspaceID: UUID) -> UUID? {
        workspaceOwners[workspaceID]
    }
    #endif

    private var projectionStateIsReady: Bool {
        guard projectionStateStore != nil else { return true }
        guard projectionStateHydrationStarted,
              projectionStateHydrated,
              pendingProjectionReleases.isEmpty else {
            return false
        }
        return Set(projectionStateClaims.keys) == Set(liveEntries().map(\.presentationID))
    }

    private func requireProjectionStateReady() throws {
        guard projectionStateStore != nil else { return }
        guard projectionStateIsReady else {
            if projectionStateHydrationStarted {
                if pendingProjectionReleases.isEmpty {
                    if projectionStateHydrationTask == nil {
                        beginProjectionStateHydration()
                    }
                } else {
                    retryPendingProjectionReleases()
                }
            }
            throw TerminalBackendTopologyProjectionError.projectionFailed(
                "daemon window projection state is still reconnecting"
            )
        }
    }

    private func beginProjectionStateHydration() {
        guard let projectionStateStore,
              projectionStateHydrationStarted,
              pendingProjectionReleases.isEmpty else {
            return
        }
        projectionStateHydrationGeneration &+= 1
        let generation = projectionStateHydrationGeneration
        projectionStateHydrated = false
        projectionStateHydrationTask?.cancel()
        projectionStateHydrationTask = nil
        projectionStatePersistenceGeneration &+= 1
        projectionStatePersistenceTask?.cancel()
        projectionStatePersistenceTask = nil
        let presentationIDs = liveEntries().map(\.presentationID)
        projectionStateHydrationTask = Task { [weak self] in
            do {
                let listed = try await projectionStateStore.listProjectionStates()
                try Task.checkCancellation()
                let liveIDs = Set(presentationIDs)
                let retainedIDs = Set(listed.map(\.logicalPresentationID))
                guard retainedIDs.isSubset(of: liveIDs) else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "daemon projection state contains a window missing from the restored app session"
                    )
                }
                var claimed: [BackendProjectionState] = []
                claimed.reserveCapacity(presentationIDs.count)
                for presentationID in presentationIDs {
                    try Task.checkCancellation()
                    claimed.append(try await projectionStateStore.claimProjectionState(
                        logicalPresentationID: presentationID
                    ))
                }
                try Task.checkCancellation()
                self?.finishProjectionStateHydration(
                    claimed,
                    expectedPresentationIDs: presentationIDs,
                    generation: generation
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.projectionStateHydrationGeneration == generation else {
                    return
                }
                self.projectionStateHydrationTask = nil
                self.projectionStateHydrated = false
            }
        }
    }

    private func finishProjectionStateHydration(
        _ states: [BackendProjectionState],
        expectedPresentationIDs: [UUID],
        generation: UInt64
    ) {
        guard projectionStateHydrationGeneration == generation,
              expectedPresentationIDs == liveEntries().map(\.presentationID),
              states.count == expectedPresentationIDs.count else {
            return
        }
        var claims: [UUID: BackendProjectionState] = [:]
        var candidateWorkspaceOwners: [UUID: UUID] = [:]
        var candidateSelectedScreens: [ScreenSelectionKey: UUID] = [:]
        for (presentationID, state) in zip(expectedPresentationIDs, states) {
            guard state.logicalPresentationID == presentationID,
                  state.claimID != nil,
                  state.generation > 0,
                  claims.updateValue(state, forKey: presentationID) == nil else {
                projectionStateHydrationTask = nil
                projectionStateHydrated = false
                return
            }
            for workspace in state.workspaces {
                let workspaceID = workspace.workspaceID.rawValue
                guard candidateWorkspaceOwners.updateValue(
                    presentationID,
                    forKey: workspaceID
                ) == nil else {
                    projectionStateHydrationTask = nil
                    projectionStateHydrated = false
                    return
                }
                candidateSelectedScreens[ScreenSelectionKey(
                    presentationID: presentationID,
                    workspaceID: workspaceID
                )] = workspace.selectedScreenID.rawValue
            }
        }
        projectionStateClaims = claims
        workspaceOwners = candidateWorkspaceOwners
        selectedScreens = candidateSelectedScreens
        projectionStateHydrationTask = nil
        projectionStateHydrated = true
        projectionStateDidChange?()
    }

    private func persistProjectionStateIfNeeded() {
        guard projectionStateStore != nil,
              projectionStateIsReady else {
            return
        }
        projectionStatePersistenceGeneration &+= 1
        guard projectionStatePersistenceTask == nil else { return }
        projectionStatePersistenceTask = Task { [weak self] in
            await self?.runProjectionStatePersistenceLoop()
        }
    }

    private func runProjectionStatePersistenceLoop() async {
        guard let projectionStateStore else {
            projectionStatePersistenceTask = nil
            return
        }
        while !Task.isCancelled {
            let generation = projectionStatePersistenceGeneration
            guard let updates = projectionStateUpdates() else {
                projectionStatePersistenceTask = nil
                return
            }
            do {
                let updated = try await projectionStateStore.updateProjectionStates(updates)
                try Task.checkCancellation()
                guard applyPersistedProjectionStates(updated, expected: updates) else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "daemon returned mismatched projection-state fences"
                    )
                }
                if generation == projectionStatePersistenceGeneration {
                    projectionStatePersistenceTask = nil
                    return
                }
            } catch is CancellationError {
                projectionStatePersistenceTask = nil
                return
            } catch {
                projectionStatePersistenceTask = nil
                projectionStateHydrated = false
                beginProjectionStateHydration()
                return
            }
        }
        projectionStatePersistenceTask = nil
    }

    private func projectionStateUpdates() -> [BackendProjectionStateUpdate]? {
        let livePresentationIDs = liveEntries().map(\.presentationID)
        var workspacesByOwner: [UUID: [(workspaceID: UUID, screenID: UUID)]] = [:]
        workspacesByOwner.reserveCapacity(livePresentationIDs.count)
        for (workspaceID, owner) in workspaceOwners {
            let key = ScreenSelectionKey(presentationID: owner, workspaceID: workspaceID)
            guard let screenID = selectedScreens[key] else { return nil }
            workspacesByOwner[owner, default: []].append((workspaceID, screenID))
        }
        var updates: [BackendProjectionStateUpdate] = []
        updates.reserveCapacity(livePresentationIDs.count)
        for presentationID in livePresentationIDs {
            guard let claim = projectionStateClaims[presentationID],
                  let claimID = claim.claimID else {
                return nil
            }
            let workspaces = (workspacesByOwner[presentationID] ?? [])
                .sorted { $0.workspaceID.uuidString < $1.workspaceID.uuidString }
                .map { workspace in
                    BackendProjectionWorkspaceState(
                        workspaceID: WorkspaceID(rawValue: workspace.workspaceID),
                        selectedScreenID: ScreenID(rawValue: workspace.screenID)
                    )
                }
            updates.append(BackendProjectionStateUpdate(
                logicalPresentationID: presentationID,
                claimID: claimID,
                expectedGeneration: claim.generation,
                workspaces: workspaces
            ))
        }
        return updates
    }

    private func applyPersistedProjectionStates(
        _ states: [BackendProjectionState],
        expected updates: [BackendProjectionStateUpdate]
    ) -> Bool {
        guard states.count == updates.count else { return false }
        var replacements = projectionStateClaims
        for (state, update) in zip(states, updates) {
            guard state.logicalPresentationID == update.logicalPresentationID,
                  state.claimID == update.claimID,
                  state.generation >= update.expectedGeneration,
                  state.workspaces == update.workspaces else {
                return false
            }
            replacements[state.logicalPresentationID] = state
        }
        projectionStateClaims = replacements
        return true
    }

    private func projectionReleaseDidFinish(_ presentationID: UUID) {
        projectionReleaseTasks.removeValue(forKey: presentationID)
        pendingProjectionReleases.remove(presentationID)
        if projectionStateHydrationStarted {
            beginProjectionStateHydration()
        }
    }

    private func projectionReleaseAttemptDidFail(_ presentationID: UUID) {
        projectionReleaseTasks.removeValue(forKey: presentationID)
        // Keep the record fail-closed. The next canonical reconciliation after
        // backend reconnect is the signal to retry without timer polling.
    }

    private func retryPendingProjectionReleases() {
        for presentationID in pendingProjectionReleases
        where projectionReleaseTasks[presentationID] == nil {
            beginProjectionRelease(presentationID, initialClaim: nil)
        }
    }

    private func liveEntries() -> [Entry] {
        registrationOrder.compactMap { entries[$0] }.filter { $0.projector != nil }
    }

    private func removeEntries(for projector: any TerminalBackendTopologyProjecting) {
        let identifiers = entries.compactMap { presentationID, entry in
            entry.projector === projector ? presentationID : nil
        }
        for identifier in identifiers {
            if let tabManager = entries[identifier]?.projector as? TabManager,
               tabManager.terminalBackendTopologyProjectionRegistry === self {
                tabManager.terminalBackendTopologyProjectionRegistry = nil
                tabManager.terminalBackendProjectionPresentationID = nil
            }
            entries.removeValue(forKey: identifier)
            registrationOrder.removeAll { $0 == identifier }
            if primaryPresentationID == identifier {
                primaryPresentationID = nil
            }
            pendingWorkspaceOwnerReservations = pendingWorkspaceOwnerReservations.filter {
                $0.value.presentationID != identifier
            }
            if emptyTopologyBootstrapClaim?.presentationID == identifier {
                emptyTopologyBootstrapClaim = nil
                projectionStateDidChange?()
            }
        }
    }

    private func purgeDeadEntries() {
        let dead = entries.compactMap { presentationID, entry in
            entry.projector == nil ? presentationID : nil
        }
        for identifier in dead {
            entries.removeValue(forKey: identifier)
            registrationOrder.removeAll { $0 == identifier }
            if primaryPresentationID == identifier {
                primaryPresentationID = nil
            }
            pendingWorkspaceOwnerReservations = pendingWorkspaceOwnerReservations.filter {
                $0.value.presentationID != identifier
            }
            if emptyTopologyBootstrapClaim?.presentationID == identifier {
                emptyTopologyBootstrapClaim = nil
            }
        }
        if primaryPresentationID == nil {
            primaryPresentationID = registrationOrder.first
        }
    }
}
