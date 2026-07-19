internal import CmuxTerminalBackend
internal import Foundation

protocol BackendOnlyProjectionDriverRPC: Sendable {
    func listAllProjectionNavigationV2(
        authority: BackendAuthority,
        expectedTopologyRevision: UInt64
    ) async throws -> BackendProjectionNavigationResponse

    func claimProjectionNavigationV2(
        logicalPresentationID: UUID,
        authority: BackendAuthority,
        expectedTopologyRevision: UInt64
    ) async throws -> BackendProjectionNavigationResponse

    func mutateProjectionNavigationV2(
        requestID: UUID,
        authority: BackendAuthority,
        expectedTopologyRevision: UInt64,
        projections: [BackendProjectionNavigationMutation]
    ) async throws -> BackendProjectionNavigationResponse
}

extension BackendCanonicalSession: BackendOnlyProjectionDriverRPC {}

nonisolated enum BackendOnlyProjectionDriverPhase: Equatable, Sendable {
    case idle
    case hydrating
    case ready
    case waitingForTopology(authority: BackendAuthority, revision: UInt64)
    case reconciliationRequired
    case superseded
    case generationExhausted
    case failed
}

nonisolated enum BackendOnlyProjectionDriverError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidTopology
    case protocolFenceMismatch
    case unexpectedConflict(BackendProjectionNavigationConflict)
    case unexpectedTopology
    case notReady
    case superseded
    case generationExhausted
    case failed
    case pendingIntentLimitExceeded(maximum: Int)
    case operationLimitExceeded(maximum: Int)
    case intentSequenceExhausted
    case ambiguousTransport
}

nonisolated struct BackendOnlyProjectionDriverMetrics: Equatable, Sendable {
    let canonicalWorkspaceVisits: Int
    let ownershipBindingVisits: Int
}

nonisolated struct BackendOnlyProjectionDriverPublication: Equatable, Sendable {
    let connectionGeneration: UInt64
    let authority: BackendAuthority
    let topologyRevision: UInt64
    let stableClientID: UUID
    let processInstanceID: UUID
    let logicalPresentationID: UUID
    let topology: CanonicalTopology
    let navigation: BackendProjectionNavigationState
}

nonisolated struct BackendOnlyProjectionDriverHydrationResult: Equatable, Sendable {
    let publication: BackendOnlyProjectionDriverPublication
    let shouldDeleteLegacySelectedWorkspace: Bool
    let metrics: BackendOnlyProjectionDriverMetrics
}

nonisolated enum BackendOnlyProjectionDriverSubmission: Equatable, Sendable {
    case queued
    case noChange
}

nonisolated enum BackendOnlyProjectionAbsoluteIntent: Equatable, Sendable {
    case workspaceAssignment(workspaceID: WorkspaceID, assigned: Bool)
    case selectWorkspace(workspaceID: WorkspaceID?)
    case selectScreen(workspaceID: WorkspaceID, screenID: ScreenID)
    case activatePane(workspaceID: WorkspaceID, screenID: ScreenID, paneID: PaneID)
    case setZoomedPane(workspaceID: WorkspaceID, screenID: ScreenID, paneID: PaneID?)
    case selectSurface(
        workspaceID: WorkspaceID,
        screenID: ScreenID,
        paneID: PaneID,
        surfaceID: SurfaceID
    )
}

private nonisolated enum BackendOnlyProjectionIntentKey: Hashable, Sendable {
    case workspaceBinding(WorkspaceID)
    case selectedWorkspace
    case selectedScreen(WorkspaceID)
    case activePane(WorkspaceID, ScreenID)
    case zoomedPane(WorkspaceID, ScreenID)
    case selectedSurface(WorkspaceID, ScreenID, PaneID)
}

private nonisolated struct BackendOnlyPendingProjectionIntent: Equatable, Sendable {
    let intent: BackendOnlyProjectionAbsoluteIntent
    let sequence: UInt64
    let withinActionOrder: Int
}

/// Serial authority owner for one stable Swift window's v2 navigation record.
actor BackendOnlyProjectionDriver {
    static let maximumPendingIntentCount = 4_096
    static let maximumOperationsPerMutation = 4_096

    let logicalPresentationID: UUID
    let stableClientID: UUID
    let processInstanceID: UUID
    let connectionGeneration: UInt64

    private(set) var phase: BackendOnlyProjectionDriverPhase = .idle
    private(set) var publication: BackendOnlyProjectionDriverPublication?
    private(set) var maximumRPCsInFlight = 0

    private var rpc: any BackendOnlyProjectionDriverRPC
    private var topologySnapshot: TopologySnapshot?
    private var navigation: BackendProjectionNavigationState?
    private var pendingIntents: [
        BackendOnlyProjectionIntentKey: BackendOnlyPendingProjectionIntent
    ] = [:]
    private var ambiguousIntents: [BackendOnlyPendingProjectionIntent] = []
    private var nextIntentSequence: UInt64 = 1
    private var drainTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var rpcsInFlight = 0

    var pendingIntentCount: Int { pendingIntents.count }

    init(
        rpc: any BackendOnlyProjectionDriverRPC,
        logicalPresentationID: UUID,
        stableClientID: UUID,
        processInstanceID: UUID,
        connectionGeneration: UInt64 = 1
    ) throws {
        guard connectionGeneration > 0,
              !Self.isNilUUID(logicalPresentationID),
              !Self.isNilUUID(stableClientID),
              !Self.isNilUUID(processInstanceID)
        else {
            throw BackendOnlyProjectionDriverError.invalidIdentity
        }
        self.rpc = rpc
        self.logicalPresentationID = logicalPresentationID
        self.stableClientID = stableClientID
        self.processInstanceID = processInstanceID
        self.connectionGeneration = connectionGeneration
        pendingIntents.reserveCapacity(Self.maximumPendingIntentCount)
    }

    func hydrate(
        topology: TopologySnapshot,
        legacySelectedWorkspaceID: WorkspaceID?
    ) async throws -> BackendOnlyProjectionDriverHydrationResult {
        guard phase != .superseded else {
            throw BackendOnlyProjectionDriverError.superseded
        }
        guard phase != .generationExhausted else {
            throw BackendOnlyProjectionDriverError.generationExhausted
        }
        guard drainTask == nil, rpcsInFlight == 0 else {
            throw BackendOnlyProjectionDriverError.notReady
        }
        phase = .hydrating
        topologySnapshot = topology
        publication = nil

        do {
            let result = try await hydrateInstalledTopology(
                legacySelectedWorkspaceID: legacySelectedWorkspaceID
            )
            phase = .ready
            startDrainIfNeeded()
            return result
        } catch let error as BackendOnlyProjectionDriverError {
            if phase == .hydrating { phase = .failed }
            throw error
        } catch {
            phase = .reconciliationRequired
            throw BackendOnlyProjectionDriverError.ambiguousTransport
        }
    }

    func submit(
        _ intents: [BackendOnlyProjectionAbsoluteIntent]
    ) async throws -> BackendOnlyProjectionDriverSubmission {
        switch phase {
        case .ready, .reconciliationRequired:
            break
        case .superseded:
            throw BackendOnlyProjectionDriverError.superseded
        case .generationExhausted:
            throw BackendOnlyProjectionDriverError.generationExhausted
        case .failed:
            throw BackendOnlyProjectionDriverError.failed
        default:
            throw BackendOnlyProjectionDriverError.notReady
        }
        guard !intents.isEmpty else { return .noChange }
        guard let topology = topologySnapshot?.topology else {
            throw BackendOnlyProjectionDriverError.notReady
        }
        for intent in intents {
            try Self.validate(intent, in: topology)
        }
        guard nextIntentSequence != UInt64.max else {
            throw BackendOnlyProjectionDriverError.intentSequenceExhausted
        }

        let sequence = nextIntentSequence
        var candidate = pendingIntents
        for (order, intent) in intents.enumerated() {
            candidate[Self.key(for: intent)] = BackendOnlyPendingProjectionIntent(
                intent: intent,
                sequence: sequence,
                withinActionOrder: order
            )
        }
        guard candidate.count <= Self.maximumPendingIntentCount else {
            throw BackendOnlyProjectionDriverError.pendingIntentLimitExceeded(
                maximum: Self.maximumPendingIntentCount
            )
        }
        nextIntentSequence += 1
        pendingIntents = candidate
        // While a mutation is admitted, the installed state predates an
        // ambiguous future result. Compare new intents only after that RPC
        // returns or after reconnect reconciliation lists authority again.
        if phase == .ready, drainTask == nil, rpcsInFlight == 0 {
            removeSatisfiedPendingIntents()
        }
        guard !pendingIntents.isEmpty else { return .noChange }
        if phase == .ready { startDrainIfNeeded() }
        return .queued
    }

    func waitUntilIdle() async {
        if drainTask == nil, rpcsInFlight == 0 { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    func reconcileAfterReconnect(
        rpc: any BackendOnlyProjectionDriverRPC,
        topology: TopologySnapshot
    ) async throws {
        guard phase == .reconciliationRequired else {
            throw BackendOnlyProjectionDriverError.notReady
        }
        guard drainTask == nil, rpcsInFlight == 0 else {
            throw BackendOnlyProjectionDriverError.notReady
        }
        self.rpc = rpc
        topologySnapshot = topology
        publication = nil
        let ambiguous = ambiguousIntents
        ambiguousIntents.removeAll(keepingCapacity: true)
        phase = .hydrating

        do {
            _ = try await hydrateInstalledTopology(
                legacySelectedWorkspaceID: nil
            )
            guard let navigation else {
                throw BackendOnlyProjectionDriverError.protocolFenceMismatch
            }
            for value in ambiguous where !Self.isSatisfied(value.intent, by: navigation) {
                let key = Self.key(for: value.intent)
                if let newer = pendingIntents[key],
                   Self.intentOrder(value, newer)
                {
                    continue
                }
                pendingIntents[key] = value
            }
            removeSatisfiedPendingIntents()
            phase = .ready
            startDrainIfNeeded()
        } catch let error as BackendOnlyProjectionDriverError {
            if phase == .hydrating { phase = .failed }
            throw error
        } catch {
            ambiguousIntents = ambiguous
            phase = .reconciliationRequired
            throw BackendOnlyProjectionDriverError.ambiguousTransport
        }
    }

    func installReplacementTopology(_ topology: TopologySnapshot) async throws {
        guard case .waitingForTopology(let authority, let revision) = phase else {
            throw BackendOnlyProjectionDriverError.notReady
        }
        guard topology.authority == authority, topology.revision == revision else {
            throw BackendOnlyProjectionDriverError.unexpectedTopology
        }
        guard drainTask == nil, rpcsInFlight == 0 else {
            throw BackendOnlyProjectionDriverError.notReady
        }
        topologySnapshot = topology
        publication = nil
        phase = .hydrating
        do {
            _ = try await hydrateInstalledTopology(
                legacySelectedWorkspaceID: nil
            )
            removeSatisfiedPendingIntents()
            phase = .ready
            startDrainIfNeeded()
        } catch let error as BackendOnlyProjectionDriverError {
            if phase == .hydrating { phase = .failed }
            throw error
        } catch {
            phase = .reconciliationRequired
            throw BackendOnlyProjectionDriverError.ambiguousTransport
        }
    }

    private func hydrateInstalledTopology(
        legacySelectedWorkspaceID: WorkspaceID?
    ) async throws -> BackendOnlyProjectionDriverHydrationResult {
        guard let snapshot = topologySnapshot else {
            throw BackendOnlyProjectionDriverError.invalidTopology
        }

        let listedResponse = try await callList(snapshot)
        let listedStates = try appliedStates(
            listedResponse,
            snapshot: snapshot,
            expectedLogicalPresentationID: nil
        )
        var owners: [WorkspaceID: UUID] = [:]
        var ownershipBindingVisits = 0
        for state in listedStates {
            for workspace in state.workspaces {
                ownershipBindingVisits += 1
                if let owner = owners[workspace.workspaceID],
                   owner != state.logicalPresentationID
                {
                    throw BackendOnlyProjectionDriverError.protocolFenceMismatch
                }
                owners[workspace.workspaceID] = state.logicalPresentationID
            }
        }

        let claimResponse = try await callClaim(snapshot)
        var state = try singleAppliedState(
            claimResponse,
            snapshot: snapshot,
            expectedLogicalPresentationID: logicalPresentationID
        )
        guard let claimID = state.claimID,
              !Self.isNilUUID(claimID),
              state.claimedProcessInstanceID == processInstanceID
        else {
            throw BackendOnlyProjectionDriverError.protocolFenceMismatch
        }
        let recordWasEmpty = state.workspaces.isEmpty
            && state.selectedWorkspaceID == nil

        var canonicalWorkspaceVisits = 0
        var assignable: [CanonicalWorkspace] = []
        assignable.reserveCapacity(snapshot.topology.workspaces.count)
        for workspace in snapshot.topology.workspaces {
            canonicalWorkspaceVisits += 1
            let owner = owners[workspace.uuid]
            if owner == nil || owner == logicalPresentationID {
                assignable.append(workspace)
            }
        }
        let alreadyAssigned = Set(state.workspaces.map(\.workspaceID))
        let missing = assignable.filter {
            !alreadyAssigned.contains($0.uuid)
        }
        var offset = 0
        while offset < missing.count {
            let end = min(
                offset + Self.maximumOperationsPerMutation,
                missing.count
            )
            let operations = missing[offset ..< end].map {
                BackendProjectionNavigationOperation.assignWorkspace(
                    workspaceID: $0.uuid
                )
            }
            state = try await mutateHydrationState(
                state,
                operations: operations,
                snapshot: snapshot
            )
            offset = end
        }

        let assignedIDs = Set(state.workspaces.map(\.workspaceID))
        let assignableIDs = Set(assignable.map(\.uuid))
        let selectableIDs = assignedIDs.intersection(assignableIDs)
        let validCurrentSelection = state.selectedWorkspaceID.flatMap {
            selectableIDs.contains($0) ? $0 : nil
        }
        let legacySeed = recordWasEmpty
            ? legacySelectedWorkspaceID.flatMap {
                selectableIDs.contains($0) ? $0 : nil
            }
            : nil
        let selectedWorkspaceID = validCurrentSelection
            ?? legacySeed
            ?? assignable.lazy.map(\.uuid).first(where: selectableIDs.contains)
        if state.selectedWorkspaceID != selectedWorkspaceID {
            state = try await mutateHydrationState(
                state,
                operations: [.selectWorkspace(workspaceID: selectedWorkspaceID)],
                snapshot: snapshot
            )
        }

        try install(state, snapshot: snapshot)
        let metrics = BackendOnlyProjectionDriverMetrics(
            canonicalWorkspaceVisits: canonicalWorkspaceVisits,
            ownershipBindingVisits: ownershipBindingVisits
        )
        return BackendOnlyProjectionDriverHydrationResult(
            publication: publication!,
            shouldDeleteLegacySelectedWorkspace: legacySelectedWorkspaceID != nil,
            metrics: metrics
        )
    }

    private func mutateHydrationState(
        _ state: BackendProjectionNavigationState,
        operations: [BackendProjectionNavigationOperation],
        snapshot: TopologySnapshot
    ) async throws -> BackendProjectionNavigationState {
        guard !operations.isEmpty,
              operations.count <= Self.maximumOperationsPerMutation,
              let claimID = state.claimID,
              state.generation != UInt64.max
        else {
            if state.generation == UInt64.max {
                phase = .generationExhausted
                throw BackendOnlyProjectionDriverError.generationExhausted
            }
            throw BackendOnlyProjectionDriverError.operationLimitExceeded(
                maximum: Self.maximumOperationsPerMutation
            )
        }
        let response = try await callMutation(
            snapshot: snapshot,
            mutation: BackendProjectionNavigationMutation(
                logicalPresentationID: logicalPresentationID,
                claimID: claimID,
                expectedGeneration: state.generation,
                operations: operations
            )
        )
        switch response {
        case .applied:
            let updated = try singleAppliedState(
                response,
                snapshot: snapshot,
                expectedLogicalPresentationID: logicalPresentationID
            )
            guard updated.generation > state.generation,
                  updated.claimID == claimID
            else {
                throw BackendOnlyProjectionDriverError.protocolFenceMismatch
            }
            return updated
        case .conflict(.generationExhausted):
            phase = .generationExhausted
            throw BackendOnlyProjectionDriverError.generationExhausted
        case .conflict(.staleTopology(
            _, let currentAuthority, _, let currentRevision
        )):
            phase = .waitingForTopology(
                authority: currentAuthority,
                revision: currentRevision
            )
            throw BackendOnlyProjectionDriverError.unexpectedTopology
        case .conflict(let conflict):
            throw BackendOnlyProjectionDriverError.unexpectedConflict(conflict)
        }
    }

    private func startDrainIfNeeded() {
        guard phase == .ready,
              drainTask == nil,
              !pendingIntents.isEmpty
        else {
            if pendingIntents.isEmpty { resumeIdleWaitersIfNeeded() }
            return
        }
        drainTask = Task { [weak self] in
            guard let self else { return }
            await self.drainPendingIntents()
        }
    }

    private func drainPendingIntents() async {
        defer {
            drainTask = nil
            resumeIdleWaitersIfNeeded()
            if phase == .ready, !pendingIntents.isEmpty {
                startDrainIfNeeded()
            }
        }

        while phase == .ready, !pendingIntents.isEmpty {
            guard let snapshot = topologySnapshot,
                  let state = navigation,
                  let claimID = state.claimID
            else {
                phase = .failed
                return
            }
            if state.generation == UInt64.max {
                phase = .generationExhausted
                pendingIntents.removeAll()
                return
            }
            removeSatisfiedPendingIntents()
            if pendingIntents.isEmpty { return }
            let sent = pendingIntents.values.sorted(by: Self.intentOrder)
            guard sent.count <= Self.maximumOperationsPerMutation else {
                phase = .failed
                return
            }
            let mutation = BackendProjectionNavigationMutation(
                logicalPresentationID: logicalPresentationID,
                claimID: claimID,
                expectedGeneration: state.generation,
                operations: sent.map { Self.operation(for: $0.intent) }
            )
            removeSentIntents(sent)

            let response: BackendProjectionNavigationResponse
            do {
                response = try await callMutation(
                    snapshot: snapshot,
                    mutation: mutation
                )
            } catch {
                ambiguousIntents = sent
                phase = .reconciliationRequired
                return
            }

            switch response {
            case .applied:
                do {
                    let current = try singleAppliedState(
                        response,
                        snapshot: snapshot,
                        expectedLogicalPresentationID: logicalPresentationID
                    )
                    guard current.generation > state.generation,
                          current.claimID == claimID
                    else {
                        throw BackendOnlyProjectionDriverError.protocolFenceMismatch
                    }
                    try install(current, snapshot: snapshot)
                    removeSatisfiedPendingIntents()
                } catch {
                    phase = .failed
                    return
                }
            case .conflict(.staleGeneration(
                let logicalID, _, _, let currentState
            )):
                guard logicalID == logicalPresentationID else {
                    phase = .failed
                    return
                }
                do {
                    try install(currentState, snapshot: snapshot)
                    removeSatisfiedPendingIntents()
                } catch {
                    phase = .failed
                    return
                }
            case .conflict(.claimLost(let logicalID, _)):
                guard logicalID == logicalPresentationID else {
                    phase = .failed
                    return
                }
                pendingIntents.removeAll()
                ambiguousIntents.removeAll()
                publication = nil
                phase = .superseded
                return
            case .conflict(.staleTopology(
                _, let currentAuthority, _, let currentRevision
            )):
                restoreSentIntents(sent)
                phase = .waitingForTopology(
                    authority: currentAuthority,
                    revision: currentRevision
                )
                publication = nil
                return
            case .conflict(.generationExhausted(let logicalID)):
                guard logicalID == logicalPresentationID else {
                    phase = .failed
                    return
                }
                pendingIntents.removeAll()
                publication = nil
                phase = .generationExhausted
                return
            case .conflict:
                phase = .failed
                return
            }
        }
    }

    private func callList(
        _ snapshot: TopologySnapshot
    ) async throws -> BackendProjectionNavigationResponse {
        beginRPC()
        defer { endRPC() }
        return try await rpc.listAllProjectionNavigationV2(
            authority: snapshot.authority,
            expectedTopologyRevision: snapshot.revision
        )
    }

    private func callClaim(
        _ snapshot: TopologySnapshot
    ) async throws -> BackendProjectionNavigationResponse {
        beginRPC()
        defer { endRPC() }
        return try await rpc.claimProjectionNavigationV2(
            logicalPresentationID: logicalPresentationID,
            authority: snapshot.authority,
            expectedTopologyRevision: snapshot.revision
        )
    }

    private func callMutation(
        snapshot: TopologySnapshot,
        mutation: BackendProjectionNavigationMutation
    ) async throws -> BackendProjectionNavigationResponse {
        beginRPC()
        defer { endRPC() }
        return try await rpc.mutateProjectionNavigationV2(
            requestID: UUID(),
            authority: snapshot.authority,
            expectedTopologyRevision: snapshot.revision,
            projections: [mutation]
        )
    }

    private func beginRPC() {
        rpcsInFlight += 1
        maximumRPCsInFlight = max(maximumRPCsInFlight, rpcsInFlight)
    }

    private func endRPC() {
        rpcsInFlight -= 1
        resumeIdleWaitersIfNeeded()
    }

    private func appliedStates(
        _ response: BackendProjectionNavigationResponse,
        snapshot: TopologySnapshot,
        expectedLogicalPresentationID: UUID?
    ) throws -> [BackendProjectionNavigationState] {
        guard case .applied(let applied) = response else {
            if case .conflict(.staleTopology(
                _, let currentAuthority, _, let currentRevision
            )) = response {
                phase = .waitingForTopology(
                    authority: currentAuthority,
                    revision: currentRevision
                )
                throw BackendOnlyProjectionDriverError.unexpectedTopology
            }
            if case .conflict(let conflict) = response {
                throw BackendOnlyProjectionDriverError.unexpectedConflict(conflict)
            }
            throw BackendOnlyProjectionDriverError.protocolFenceMismatch
        }
        guard applied.topologyRevision == snapshot.revision else {
            throw BackendOnlyProjectionDriverError.protocolFenceMismatch
        }
        for state in applied.states {
            guard state.reconciledTopologyRevision == snapshot.revision,
                  expectedLogicalPresentationID == nil
                    || state.logicalPresentationID == expectedLogicalPresentationID
            else {
                throw BackendOnlyProjectionDriverError.protocolFenceMismatch
            }
        }
        return applied.states
    }

    private func singleAppliedState(
        _ response: BackendProjectionNavigationResponse,
        snapshot: TopologySnapshot,
        expectedLogicalPresentationID: UUID
    ) throws -> BackendProjectionNavigationState {
        let states = try appliedStates(
            response,
            snapshot: snapshot,
            expectedLogicalPresentationID: expectedLogicalPresentationID
        )
        guard states.count == 1, let state = states.first else {
            throw BackendOnlyProjectionDriverError.protocolFenceMismatch
        }
        return state
    }

    private func install(
        _ state: BackendProjectionNavigationState,
        snapshot: TopologySnapshot
    ) throws {
        guard state.logicalPresentationID == logicalPresentationID,
              state.reconciledTopologyRevision == snapshot.revision,
              state.claimID != nil,
              state.claimedProcessInstanceID == processInstanceID
        else {
            throw BackendOnlyProjectionDriverError.protocolFenceMismatch
        }
        navigation = state
        publication = BackendOnlyProjectionDriverPublication(
            connectionGeneration: connectionGeneration,
            authority: snapshot.authority,
            topologyRevision: snapshot.revision,
            stableClientID: stableClientID,
            processInstanceID: processInstanceID,
            logicalPresentationID: logicalPresentationID,
            topology: snapshot.topology,
            navigation: state
        )
    }

    private func removeSentIntents(
        _ sent: [BackendOnlyPendingProjectionIntent]
    ) {
        for value in sent {
            let key = Self.key(for: value.intent)
            guard pendingIntents[key] == value else { continue }
            pendingIntents.removeValue(forKey: key)
        }
    }

    private func restoreSentIntents(
        _ sent: [BackendOnlyPendingProjectionIntent]
    ) {
        for value in sent {
            let key = Self.key(for: value.intent)
            if let newer = pendingIntents[key],
               Self.intentOrder(value, newer)
            {
                continue
            }
            pendingIntents[key] = value
        }
    }

    private func removeSatisfiedPendingIntents() {
        guard let navigation else { return }
        pendingIntents = pendingIntents.filter {
            !Self.isSatisfied($0.value.intent, by: navigation)
        }
    }

    private func resumeIdleWaitersIfNeeded() {
        guard drainTask == nil, rpcsInFlight == 0 else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private static func key(
        for intent: BackendOnlyProjectionAbsoluteIntent
    ) -> BackendOnlyProjectionIntentKey {
        switch intent {
        case .workspaceAssignment(let workspaceID, _):
            .workspaceBinding(workspaceID)
        case .selectWorkspace:
            .selectedWorkspace
        case .selectScreen(let workspaceID, _):
            .selectedScreen(workspaceID)
        case .activatePane(let workspaceID, let screenID, _):
            .activePane(workspaceID, screenID)
        case .setZoomedPane(let workspaceID, let screenID, _):
            .zoomedPane(workspaceID, screenID)
        case .selectSurface(let workspaceID, let screenID, let paneID, _):
            .selectedSurface(workspaceID, screenID, paneID)
        }
    }

    private static func operation(
        for intent: BackendOnlyProjectionAbsoluteIntent
    ) -> BackendProjectionNavigationOperation {
        switch intent {
        case .workspaceAssignment(let workspaceID, let assigned):
            assigned
                ? .assignWorkspace(workspaceID: workspaceID)
                : .unassignWorkspace(workspaceID: workspaceID)
        case .selectWorkspace(let workspaceID):
            .selectWorkspace(workspaceID: workspaceID)
        case .selectScreen(let workspaceID, let screenID):
            .selectScreen(workspaceID: workspaceID, screenID: screenID)
        case .activatePane(let workspaceID, let screenID, let paneID):
            .activatePane(
                workspaceID: workspaceID,
                screenID: screenID,
                paneID: paneID
            )
        case .setZoomedPane(let workspaceID, let screenID, let paneID):
            .setZoomedPane(
                workspaceID: workspaceID,
                screenID: screenID,
                paneID: paneID
            )
        case .selectSurface(
            let workspaceID,
            let screenID,
            let paneID,
            let surfaceID
        ):
            .selectSurface(
                workspaceID: workspaceID,
                screenID: screenID,
                paneID: paneID,
                surfaceID: surfaceID
            )
        }
    }

    private static func intentOrder(
        _ lhs: BackendOnlyPendingProjectionIntent,
        _ rhs: BackendOnlyPendingProjectionIntent
    ) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.withinActionOrder < rhs.withinActionOrder
    }

    private static func isSatisfied(
        _ intent: BackendOnlyProjectionAbsoluteIntent,
        by state: BackendProjectionNavigationState
    ) -> Bool {
        switch intent {
        case .workspaceAssignment(let workspaceID, let assigned):
            state.workspaces.contains { $0.workspaceID == workspaceID }
                == assigned
        case .selectWorkspace(let workspaceID):
            state.selectedWorkspaceID == workspaceID
        case .selectScreen(let workspaceID, let screenID):
            state.workspaces.first { $0.workspaceID == workspaceID }?
                .selectedScreenID == screenID
        case .activatePane(let workspaceID, let screenID, let paneID):
            screenState(state, workspaceID: workspaceID, screenID: screenID)?
                .activePaneID == paneID
        case .setZoomedPane(let workspaceID, let screenID, let paneID):
            guard let screen = screenState(
                state,
                workspaceID: workspaceID,
                screenID: screenID
            ) else { return false }
            return screen.zoomedPaneID == paneID
        case .selectSurface(
            let workspaceID,
            let screenID,
            let paneID,
            let surfaceID
        ):
            screenState(state, workspaceID: workspaceID, screenID: screenID)?
                .panes.first { $0.paneID == paneID }?
                .selectedSurfaceID == surfaceID
        }
    }

    private static func screenState(
        _ state: BackendProjectionNavigationState,
        workspaceID: WorkspaceID,
        screenID: ScreenID
    ) -> BackendProjectionNavigationScreenState? {
        state.workspaces.first { $0.workspaceID == workspaceID }?
            .screens.first { $0.screenID == screenID }
    }

    private static func validate(
        _ intent: BackendOnlyProjectionAbsoluteIntent,
        in topology: CanonicalTopology
    ) throws {
        switch intent {
        case .workspaceAssignment(let workspaceID, _):
            guard topology.workspaces.contains(where: { $0.uuid == workspaceID }) else {
                throw BackendOnlyProjectionDriverError.invalidTopology
            }
        case .selectWorkspace(let workspaceID):
            guard workspaceID == nil
                    || topology.workspaces.contains(where: { $0.uuid == workspaceID })
            else {
                throw BackendOnlyProjectionDriverError.invalidTopology
            }
        case .selectScreen(let workspaceID, let screenID):
            guard findScreen(topology, workspaceID: workspaceID, screenID: screenID) != nil else {
                throw BackendOnlyProjectionDriverError.invalidTopology
            }
        case .activatePane(let workspaceID, let screenID, let paneID):
            guard findScreen(
                topology,
                workspaceID: workspaceID,
                screenID: screenID
            )?.panes.contains(where: { $0.uuid == paneID }) == true else {
                throw BackendOnlyProjectionDriverError.invalidTopology
            }
        case .setZoomedPane(let workspaceID, let screenID, let paneID):
            guard let screen = findScreen(
                topology,
                workspaceID: workspaceID,
                screenID: screenID
            ), paneID == nil || screen.panes.contains(where: { $0.uuid == paneID })
            else {
                throw BackendOnlyProjectionDriverError.invalidTopology
            }
        case .selectSurface(
            let workspaceID,
            let screenID,
            let paneID,
            let surfaceID
        ):
            guard findScreen(
                topology,
                workspaceID: workspaceID,
                screenID: screenID
            )?.panes.first(where: { $0.uuid == paneID })?
                .tabs.contains(where: { $0.uuid == surfaceID }) == true else {
                throw BackendOnlyProjectionDriverError.invalidTopology
            }
        }
    }

    private static func findScreen(
        _ topology: CanonicalTopology,
        workspaceID: WorkspaceID,
        screenID: ScreenID
    ) -> CanonicalScreen? {
        topology.workspaces.first { $0.uuid == workspaceID }?
            .screens.first { $0.uuid == screenID }
    }

    private static func isNilUUID(_ value: UUID) -> Bool {
        value == UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
    }
}
