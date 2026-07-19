import CmuxTerminalBackend
@testable import CmuxTerminalBackendHost
import Foundation
import Testing

@Suite("Backend-only projection driver")
struct BackendOnlyProjectionDriverTests {
    @Test("hydration excludes foreign ownership and preserves valid selection")
    func hydrationRespectsForeignOwnership() async throws {
        let fixture = try DriverFixture(workspaceCount: 3)
        let target = fixture.state(
            generation: 4,
            workspaceIndexes: [0],
            selectedWorkspaceIndex: 0
        )
        let foreign = fixture.state(
            logicalPresentationID: driverUUID(900),
            generation: 2,
            workspaceIndexes: [1],
            selectedWorkspaceIndex: 1
        )
        await fixture.rpc.install(records: [foreign, target])

        let result = try await fixture.driver.hydrate(
            topology: fixture.snapshot,
            legacySelectedWorkspaceID: fixture.workspace(2).uuid
        )

        #expect(result.shouldDeleteLegacySelectedWorkspace)
        #expect(result.publication.navigation.selectedWorkspaceID == fixture.workspace(0).uuid)
        #expect(
            result.publication.navigation.workspaces.map(\.workspaceID)
                == [fixture.workspace(0).uuid, fixture.workspace(2).uuid]
        )
        #expect(!result.publication.navigation.workspaces.contains {
            $0.workspaceID == fixture.workspace(1).uuid
        })
        let operations = await fixture.rpc.mutationOperations().flatMap { $0 }
        #expect(operations == [
            .assignWorkspace(workspaceID: fixture.workspace(2).uuid),
        ])
    }

    @Test("empty record consumes one-time legacy seed after canonical assignment")
    func legacySeedAppliesOnlyToEmptyRecord() async throws {
        let fixture = try DriverFixture(workspaceCount: 3)

        let result = try await fixture.driver.hydrate(
            topology: fixture.snapshot,
            legacySelectedWorkspaceID: fixture.workspace(1).uuid
        )

        #expect(result.shouldDeleteLegacySelectedWorkspace)
        #expect(result.publication.navigation.selectedWorkspaceID == fixture.workspace(1).uuid)
        #expect(
            result.publication.navigation.workspaces.map(\.workspaceID)
                == fixture.topology.workspaces.map(\.uuid)
        )
        let batches = await fixture.rpc.mutationOperations()
        #expect(batches.count == 2)
        #expect(batches[0] == fixture.topology.workspaces.map {
            .assignWorkspace(workspaceID: $0.uuid)
        })
        #expect(batches[1] == [
            .selectWorkspace(workspaceID: fixture.workspace(1).uuid),
        ])
    }

    @Test("hydration batches the 4096 operation limit exactly")
    func hydrationBatchesAtOperationLimit() async throws {
        let fixture = try DriverFixture(workspaceCount: 4_096)

        let result = try await fixture.driver.hydrate(
            topology: fixture.snapshot,
            legacySelectedWorkspaceID: nil
        )

        let batches = await fixture.rpc.mutationOperations()
        #expect(batches.map(\.count) == [4_096, 1])
        #expect(result.publication.navigation.workspaces.count == 4_096)
        #expect(
            result.publication.navigation.selectedWorkspaceID
                == fixture.topology.workspaces.first?.uuid
        )
    }

    @Test("publication rejects navigation and topology fence mismatch")
    func hydrationRejectsFenceMismatch() async throws {
        let fixture = try DriverFixture(workspaceCount: 1)
        await fixture.rpc.overrideNextClaimTopologyRevision(
            fixture.snapshot.revision + 1
        )

        await #expect(
            throws: BackendOnlyProjectionDriverError.protocolFenceMismatch
        ) {
            _ = try await fixture.driver.hydrate(
                topology: fixture.snapshot,
                legacySelectedWorkspaceID: nil
            )
        }
        #expect(await fixture.driver.publication == nil)
    }

    @Test("absolute intents coalesce by target and preserve action order")
    func absoluteIntentsCoalesceAndRemainOrdered() async throws {
        let fixture = try DriverFixture(topology: try intentTopology())
        _ = try await fixture.driver.hydrate(
            topology: fixture.snapshot,
            legacySelectedWorkspaceID: nil
        )
        await fixture.rpc.clearMutationLog()
        await fixture.rpc.blockNextMutation()
        let workspace = fixture.workspace(0)
        let screen = workspace.screens[0]
        let firstPane = screen.panes[0]
        let secondPane = screen.panes[1]

        let inFlight = Task {
            try await fixture.driver.submit([
                .selectSurface(
                    workspaceID: workspace.uuid,
                    screenID: screen.uuid,
                    paneID: firstPane.uuid,
                    surfaceID: firstPane.tabs[1].uuid
                ),
            ])
        }
        await fixture.rpc.waitUntilMutationStarted(count: 1)

        _ = try await fixture.driver.submit([
            .activatePane(
                workspaceID: workspace.uuid,
                screenID: screen.uuid,
                paneID: secondPane.uuid
            ),
            .setZoomedPane(
                workspaceID: workspace.uuid,
                screenID: screen.uuid,
                paneID: secondPane.uuid
            ),
            .selectSurface(
                workspaceID: workspace.uuid,
                screenID: screen.uuid,
                paneID: firstPane.uuid,
                surfaceID: firstPane.tabs[0].uuid
            ),
        ])
        _ = try await fixture.driver.submit([
            .activatePane(
                workspaceID: workspace.uuid,
                screenID: screen.uuid,
                paneID: firstPane.uuid
            ),
            .setZoomedPane(
                workspaceID: workspace.uuid,
                screenID: screen.uuid,
                paneID: firstPane.uuid
            ),
            .selectSurface(
                workspaceID: workspace.uuid,
                screenID: screen.uuid,
                paneID: firstPane.uuid,
                surfaceID: firstPane.tabs[1].uuid
            ),
        ])
        #expect(await fixture.driver.pendingIntentCount == 3)
        #expect(await fixture.driver.maximumRPCsInFlight == 1)

        await fixture.rpc.releaseBlockedMutation()
        _ = try await inFlight.value
        await fixture.rpc.waitUntilMutationStarted(count: 2)
        await fixture.driver.waitUntilIdle()

        let batches = await fixture.rpc.mutationOperations()
        #expect(batches.count == 2)
        #expect(batches[1] == [
            .activatePane(
                workspaceID: workspace.uuid,
                screenID: screen.uuid,
                paneID: firstPane.uuid
            ),
            .setZoomedPane(
                workspaceID: workspace.uuid,
                screenID: screen.uuid,
                paneID: firstPane.uuid
            ),
            .selectSurface(
                workspaceID: workspace.uuid,
                screenID: screen.uuid,
                paneID: firstPane.uuid,
                surfaceID: firstPane.tabs[1].uuid
            ),
        ])
        #expect(await fixture.rpc.maximumMutationsInFlight() == 1)
    }

    @Test("stale generation installs current state and replays only newer intents")
    func staleGenerationRebasesNewerIntents() async throws {
        let fixture = try DriverFixture(workspaceCount: 2)
        _ = try await fixture.driver.hydrate(
            topology: fixture.snapshot,
            legacySelectedWorkspaceID: nil
        )
        await fixture.rpc.clearMutationLog()
        let staleCurrent = try #require(await fixture.rpc.record(fixture.logicalPresentationID))
        await fixture.rpc.blockNextMutation()
        await fixture.rpc.setBlockedMutationConflict(
            .staleGeneration(
                logicalPresentationID: fixture.logicalPresentationID,
                expected: staleCurrent.generation,
                current: staleCurrent.generation + 1,
                currentState: fixture.copy(
                    staleCurrent,
                    generation: staleCurrent.generation + 1
                )
            )
        )

        let oldIntent = Task {
            try await fixture.driver.submit([
                .selectWorkspace(workspaceID: fixture.workspace(1).uuid),
            ])
        }
        await fixture.rpc.waitUntilMutationStarted(count: 1)
        _ = try await fixture.driver.submit([
            .setZoomedPane(
                workspaceID: fixture.workspace(0).uuid,
                screenID: fixture.workspace(0).screens[0].uuid,
                paneID: fixture.workspace(0).screens[0].panes[0].uuid
            ),
        ])
        await fixture.rpc.releaseBlockedMutation()
        _ = try await oldIntent.value
        await fixture.driver.waitUntilIdle()

        let batches = await fixture.rpc.mutationOperations()
        #expect(batches == [
            [.selectWorkspace(workspaceID: fixture.workspace(1).uuid)],
            [
                .setZoomedPane(
                    workspaceID: fixture.workspace(0).uuid,
                    screenID: fixture.workspace(0).screens[0].uuid,
                    paneID: fixture.workspace(0).screens[0].panes[0].uuid
                ),
            ],
        ])
        #expect(
            await fixture.driver.publication?.navigation.workspaces[0]
                .screens[0].zoomedPaneID
                == fixture.workspace(0).screens[0].panes[0].uuid
        )
    }

    @Test("claim loss is terminal and never starts a reclaim loop")
    func claimLossSupersedesDriver() async throws {
        let fixture = try DriverFixture(workspaceCount: 1)
        _ = try await fixture.driver.hydrate(
            topology: fixture.snapshot,
            legacySelectedWorkspaceID: nil
        )
        await fixture.rpc.setNextMutationConflict(
            .claimLost(
                logicalPresentationID: fixture.logicalPresentationID,
                claimedProcessInstanceID: driverUUID(999)
            )
        )

        _ = try await fixture.driver.submit([
            .setZoomedPane(
                workspaceID: fixture.workspace(0).uuid,
                screenID: fixture.workspace(0).screens[0].uuid,
                paneID: fixture.workspace(0).screens[0].panes[0].uuid
            ),
        ])
        await fixture.driver.waitUntilIdle()

        #expect(await fixture.driver.phase == .superseded)
        #expect(await fixture.rpc.claimCount() == 1)
        await #expect(throws: BackendOnlyProjectionDriverError.superseded) {
            _ = try await fixture.driver.submit([
                .setZoomedPane(
                    workspaceID: fixture.workspace(0).uuid,
                    screenID: fixture.workspace(0).screens[0].uuid,
                    paneID: fixture.workspace(0).screens[0].panes[0].uuid
                ),
            ])
        }
    }

    @Test("ambiguous failure lists and compares before replaying unmet intent")
    func ambiguousFailureRequiresReconciliation() async throws {
        let fixture = try DriverFixture(workspaceCount: 2)
        _ = try await fixture.driver.hydrate(
            topology: fixture.snapshot,
            legacySelectedWorkspaceID: nil
        )
        await fixture.rpc.failNextMutationAmbiguously()

        _ = try await fixture.driver.submit([
            .selectWorkspace(workspaceID: fixture.workspace(1).uuid),
        ])
        await fixture.driver.waitUntilIdle()
        #expect(await fixture.driver.phase == .reconciliationRequired)

        let reconnectRPC = DriverFakeRPC(
            topology: fixture.topology,
            authority: fixture.snapshot.authority,
            topologyRevision: fixture.snapshot.revision,
            processInstanceID: fixture.processInstanceID
        )
        let authoritative = try #require(await fixture.rpc.record(
            fixture.logicalPresentationID
        ))
        await reconnectRPC.install(records: [authoritative])
        try await fixture.driver.reconcileAfterReconnect(
            rpc: reconnectRPC,
            topology: fixture.snapshot
        )
        await fixture.driver.waitUntilIdle()

        #expect(await reconnectRPC.calls().prefix(2) == [.list, .claim])
        #expect(await reconnectRPC.mutationOperations() == [[
            .selectWorkspace(workspaceID: fixture.workspace(1).uuid),
        ]])
        #expect(await fixture.driver.phase == .ready)
    }

    @Test("stale topology waits for the exact replacement snapshot")
    func staleTopologyWaitsForExactReplacement() async throws {
        let fixture = try DriverFixture(workspaceCount: 1)
        _ = try await fixture.driver.hydrate(
            topology: fixture.snapshot,
            legacySelectedWorkspaceID: nil
        )
        let replacement = TopologySnapshot(
            authority: fixture.snapshot.authority,
            revision: fixture.snapshot.revision + 1,
            topology: fixture.topology
        )
        await fixture.rpc.setNextMutationConflict(
            .staleTopology(
                expectedAuthority: fixture.snapshot.authority,
                currentAuthority: replacement.authority,
                expectedRevision: fixture.snapshot.revision,
                currentRevision: replacement.revision
            )
        )

        _ = try await fixture.driver.submit([
            .setZoomedPane(
                workspaceID: fixture.workspace(0).uuid,
                screenID: fixture.workspace(0).screens[0].uuid,
                paneID: fixture.workspace(0).screens[0].panes[0].uuid
            ),
        ])
        await fixture.driver.waitUntilIdle()
        #expect(
            await fixture.driver.phase
                == .waitingForTopology(
                    authority: replacement.authority,
                    revision: replacement.revision
                )
        )

        await #expect(throws: BackendOnlyProjectionDriverError.unexpectedTopology) {
            try await fixture.driver.installReplacementTopology(fixture.snapshot)
        }
        await fixture.rpc.installTopologyRevision(replacement.revision)
        try await fixture.driver.installReplacementTopology(replacement)
        #expect(await fixture.driver.phase == .ready)
    }

    @Test("generation exhaustion is terminal")
    func generationExhaustionIsTerminal() async throws {
        let fixture = try DriverFixture(workspaceCount: 1)
        _ = try await fixture.driver.hydrate(
            topology: fixture.snapshot,
            legacySelectedWorkspaceID: nil
        )
        await fixture.rpc.setNextMutationConflict(
            .generationExhausted(
                logicalPresentationID: fixture.logicalPresentationID
            )
        )

        _ = try await fixture.driver.submit([
            .setZoomedPane(
                workspaceID: fixture.workspace(0).uuid,
                screenID: fixture.workspace(0).screens[0].uuid,
                paneID: fixture.workspace(0).screens[0].panes[0].uuid
            ),
        ])
        await fixture.driver.waitUntilIdle()

        #expect(await fixture.driver.phase == .generationExhausted)
        await #expect(
            throws: BackendOnlyProjectionDriverError.generationExhausted
        ) {
            _ = try await fixture.driver.submit([
                .setZoomedPane(
                    workspaceID: fixture.workspace(0).uuid,
                    screenID: fixture.workspace(0).screens[0].uuid,
                    paneID: fixture.workspace(0).screens[0].panes[0].uuid
                ),
            ])
        }
    }

    @Test("pending intent map rejects 4097 distinct targets atomically")
    func pendingIntentBoundIsAtomic() async throws {
        let fixture = try DriverFixture(workspaceCount: 4_096)
        _ = try await fixture.driver.hydrate(
            topology: fixture.snapshot,
            legacySelectedWorkspaceID: nil
        )
        await fixture.rpc.blockNextMutation()
        let first = fixture.workspace(0)
        let baselineMutationCount = await fixture.rpc.mutationCount()
        let inFlight = Task {
            try await fixture.driver.submit([
                .workspaceAssignment(workspaceID: first.uuid, assigned: false),
            ])
        }
        await fixture.rpc.waitUntilMutationStarted(
            count: baselineMutationCount + 1
        )
        let intents = fixture.topology.workspaces.map {
            BackendOnlyProjectionAbsoluteIntent.workspaceAssignment(
                workspaceID: $0.uuid,
                assigned: true
            )
        } + [
            .selectWorkspace(workspaceID: first.uuid),
        ]

        await #expect(
            throws: BackendOnlyProjectionDriverError.pendingIntentLimitExceeded(
                maximum: 4_096
            )
        ) {
            _ = try await fixture.driver.submit(intents)
        }
        #expect(await fixture.driver.pendingIntentCount == 0)
        await fixture.rpc.releaseBlockedMutation()
        _ = try await inFlight.value
    }

    @Test("1000-workspace hydration visits canonical order once")
    func thousandWorkspaceHydrationIsLinear() async throws {
        let fixture = try DriverFixture(workspaceCount: 1_000)

        let result = try await fixture.driver.hydrate(
            topology: fixture.snapshot,
            legacySelectedWorkspaceID: nil
        )

        #expect(result.metrics.canonicalWorkspaceVisits == 1_000)
        #expect(result.metrics.ownershipBindingVisits == 0)
        #expect(result.publication.navigation.workspaces.count == 1_000)
        #expect(await fixture.rpc.mutationOperations().first?.count == 1_000)
    }
}

private struct DriverFixture: Sendable {
    let logicalPresentationID = driverUUID(1)
    let stableClientID = driverUUID(2)
    let processInstanceID = driverUUID(3)
    let topology: CanonicalTopology
    let snapshot: TopologySnapshot
    let rpc: DriverFakeRPC
    let driver: BackendOnlyProjectionDriver

    init(workspaceCount: Int) throws {
        try self.init(topology: makeDriverTopology(workspaceCount: workspaceCount))
    }

    init(topology: CanonicalTopology) throws {
        self.topology = topology
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: driverUUID(4)),
            sessionID: SessionID(rawValue: driverUUID(5))
        )
        snapshot = TopologySnapshot(
            authority: authority,
            revision: 7,
            topology: topology
        )
        rpc = DriverFakeRPC(
            topology: topology,
            authority: authority,
            topologyRevision: 7,
            processInstanceID: processInstanceID
        )
        driver = try BackendOnlyProjectionDriver(
            rpc: rpc,
            logicalPresentationID: logicalPresentationID,
            stableClientID: stableClientID,
            processInstanceID: processInstanceID
        )
    }

    func workspace(_ index: Int) -> CanonicalWorkspace {
        topology.workspaces[index]
    }

    func state(
        logicalPresentationID: UUID? = nil,
        generation: UInt64,
        workspaceIndexes: [Int],
        selectedWorkspaceIndex: Int?
    ) -> BackendProjectionNavigationState {
        BackendProjectionNavigationState(
            logicalPresentationID: logicalPresentationID ?? self.logicalPresentationID,
            generation: generation,
            claimID: nil,
            claimedProcessInstanceID: nil,
            reconciledTopologyRevision: snapshot.revision,
            selectedWorkspaceID: selectedWorkspaceIndex.map { workspace($0).uuid },
            workspaces: workspaceIndexes.map { defaultWorkspaceState(workspace($0)) }
        )
    }

    func copy(
        _ state: BackendProjectionNavigationState,
        generation: UInt64
    ) -> BackendProjectionNavigationState {
        BackendProjectionNavigationState(
            logicalPresentationID: state.logicalPresentationID,
            generation: generation,
            claimID: state.claimID,
            claimedProcessInstanceID: state.claimedProcessInstanceID,
            reconciledTopologyRevision: state.reconciledTopologyRevision,
            selectedWorkspaceID: state.selectedWorkspaceID,
            workspaces: state.workspaces
        )
    }
}

private actor DriverFakeRPC: BackendOnlyProjectionDriverRPC {
    enum Call: Equatable, Sendable {
        case list
        case claim
        case mutate
    }

    enum AmbiguousFailure: Error {
        case transportClosed
    }

    private let topology: CanonicalTopology
    private let workspacesByID: [WorkspaceID: CanonicalWorkspace]
    private let authority: BackendAuthority
    private var topologyRevision: UInt64
    private let processInstanceID: UUID
    private var records: [UUID: BackendProjectionNavigationState] = [:]
    private var callLog: [Call] = []
    private var mutations: [[BackendProjectionNavigationOperation]] = []
    private var nextMutationConflict: BackendProjectionNavigationConflict?
    private var blockedMutationConflict: BackendProjectionNavigationConflict?
    private var nextMutationIsAmbiguous = false
    private var blockedMutation = false
    private var blockedMutationContinuation: CheckedContinuation<Void, Never>?
    private var mutationStartWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var mutationsInFlight = 0
    private var maximumMutationInFlight = 0
    private var claimTopologyRevisionOverride: UInt64?

    init(
        topology: CanonicalTopology,
        authority: BackendAuthority,
        topologyRevision: UInt64,
        processInstanceID: UUID
    ) {
        self.topology = topology
        workspacesByID = Dictionary(uniqueKeysWithValues: topology.workspaces.map {
            ($0.uuid, $0)
        })
        self.authority = authority
        self.topologyRevision = topologyRevision
        self.processInstanceID = processInstanceID
    }

    func install(records: [BackendProjectionNavigationState]) {
        self.records = Dictionary(uniqueKeysWithValues: records.map {
            ($0.logicalPresentationID, $0)
        })
    }

    func listAllProjectionNavigationV2(
        authority _: BackendAuthority,
        expectedTopologyRevision _: UInt64
    ) async throws -> BackendProjectionNavigationResponse {
        callLog.append(.list)
        return .applied(BackendProjectionNavigationApplied(
            topologyRevision: topologyRevision,
            clientRevision: 1,
            states: records.values.sorted {
                $0.logicalPresentationID.uuidString
                    < $1.logicalPresentationID.uuidString
            }
        ))
    }

    func claimProjectionNavigationV2(
        logicalPresentationID: UUID,
        authority _: BackendAuthority,
        expectedTopologyRevision _: UInt64
    ) async throws -> BackendProjectionNavigationResponse {
        callLog.append(.claim)
        let existing = records[logicalPresentationID]
        let claimed = BackendProjectionNavigationState(
            logicalPresentationID: logicalPresentationID,
            generation: (existing?.generation ?? 0) + 1,
            claimID: driverUUID(700 + UInt64(callLog.count)),
            claimedProcessInstanceID: processInstanceID,
            reconciledTopologyRevision: topologyRevision,
            selectedWorkspaceID: existing?.selectedWorkspaceID,
            workspaces: existing?.workspaces ?? []
        )
        records[logicalPresentationID] = claimed
        return .applied(BackendProjectionNavigationApplied(
            topologyRevision: claimTopologyRevisionOverride ?? topologyRevision,
            states: [claimed]
        ))
    }

    func mutateProjectionNavigationV2(
        requestID _: UUID,
        authority _: BackendAuthority,
        expectedTopologyRevision _: UInt64,
        projections: [BackendProjectionNavigationMutation]
    ) async throws -> BackendProjectionNavigationResponse {
        callLog.append(.mutate)
        mutationsInFlight += 1
        maximumMutationInFlight = max(maximumMutationInFlight, mutationsInFlight)
        defer { mutationsInFlight -= 1 }
        let operations = projections.flatMap(\.operations)
        mutations.append(operations)
        resumeMutationStartWaiters()
        if blockedMutation {
            await withCheckedContinuation { continuation in
                blockedMutationContinuation = continuation
            }
        }
        if let conflict = blockedMutationConflict {
            blockedMutationConflict = nil
            return .conflict(conflict)
        }
        if let conflict = nextMutationConflict {
            nextMutationConflict = nil
            return .conflict(conflict)
        }
        if nextMutationIsAmbiguous {
            nextMutationIsAmbiguous = false
            throw AmbiguousFailure.transportClosed
        }
        let states = try projections.map { mutation in
            let current = records[mutation.logicalPresentationID]!
            let updated = apply(
                operations: mutation.operations,
                to: current,
                generation: current.generation + 1
            )
            records[mutation.logicalPresentationID] = updated
            return updated
        }
        return .applied(BackendProjectionNavigationApplied(
            topologyRevision: topologyRevision,
            states: states
        ))
    }

    func setNextMutationConflict(_ conflict: BackendProjectionNavigationConflict) {
        nextMutationConflict = conflict
    }

    func setBlockedMutationConflict(_ conflict: BackendProjectionNavigationConflict) {
        blockedMutationConflict = conflict
    }

    func failNextMutationAmbiguously() {
        nextMutationIsAmbiguous = true
    }

    func blockNextMutation() {
        blockedMutation = true
    }

    func releaseBlockedMutation() {
        blockedMutation = false
        let continuation = blockedMutationContinuation
        blockedMutationContinuation = nil
        continuation?.resume()
    }

    func waitUntilMutationStarted(count: Int) async {
        if mutations.count >= count { return }
        await withCheckedContinuation { continuation in
            mutationStartWaiters.append((count, continuation))
        }
    }

    func clearMutationLog() {
        mutations.removeAll()
    }

    func overrideNextClaimTopologyRevision(_ revision: UInt64) {
        claimTopologyRevisionOverride = revision
    }

    func installTopologyRevision(_ revision: UInt64) {
        topologyRevision = revision
    }

    func record(_ logicalPresentationID: UUID) -> BackendProjectionNavigationState? {
        records[logicalPresentationID]
    }

    func mutationOperations() -> [[BackendProjectionNavigationOperation]] {
        mutations
    }

    func mutationCount() -> Int { mutations.count }
    func maximumMutationsInFlight() -> Int { maximumMutationInFlight }
    func calls() -> [Call] { callLog }
    func claimCount() -> Int { callLog.count(where: { $0 == .claim }) }

    private func resumeMutationStartWaiters() {
        var retained: [
            (count: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in mutationStartWaiters {
            if mutations.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                retained.append(waiter)
            }
        }
        mutationStartWaiters = retained
    }

    private func apply(
        operations: [BackendProjectionNavigationOperation],
        to original: BackendProjectionNavigationState,
        generation: UInt64
    ) -> BackendProjectionNavigationState {
        var selectedWorkspaceID = original.selectedWorkspaceID
        var workspaces = original.workspaces
        for operation in operations {
            switch operation {
            case .assignWorkspace(let workspaceID):
                if !workspaces.contains(where: { $0.workspaceID == workspaceID }),
                   let workspace = workspacesByID[workspaceID]
                {
                    workspaces.append(defaultWorkspaceState(workspace))
                }
            case .unassignWorkspace(let workspaceID):
                workspaces.removeAll { $0.workspaceID == workspaceID }
                if selectedWorkspaceID == workspaceID { selectedWorkspaceID = nil }
            case .selectWorkspace(let workspaceID):
                selectedWorkspaceID = workspaceID
            case .selectScreen(let workspaceID, let screenID):
                workspaces = workspaces.map { workspace in
                    guard workspace.workspaceID == workspaceID else { return workspace }
                    return BackendProjectionNavigationWorkspaceState(
                        workspaceID: workspace.workspaceID,
                        selectedScreenID: screenID,
                        screens: workspace.screens
                    )
                }
            case .activatePane(let workspaceID, let screenID, let paneID):
                workspaces = mapScreen(
                    workspaces,
                    workspaceID: workspaceID,
                    screenID: screenID
                ) { screen in
                    BackendProjectionNavigationScreenState(
                        screenID: screen.screenID,
                        activePaneID: paneID,
                        zoomedPaneID: screen.zoomedPaneID,
                        panes: screen.panes
                    )
                }
            case .setZoomedPane(let workspaceID, let screenID, let paneID):
                workspaces = mapScreen(
                    workspaces,
                    workspaceID: workspaceID,
                    screenID: screenID
                ) { screen in
                    BackendProjectionNavigationScreenState(
                        screenID: screen.screenID,
                        activePaneID: screen.activePaneID,
                        zoomedPaneID: paneID,
                        panes: screen.panes
                    )
                }
            case .selectSurface(
                let workspaceID,
                let screenID,
                let paneID,
                let surfaceID
            ):
                workspaces = mapScreen(
                    workspaces,
                    workspaceID: workspaceID,
                    screenID: screenID
                ) { screen in
                    BackendProjectionNavigationScreenState(
                        screenID: screen.screenID,
                        activePaneID: screen.activePaneID,
                        zoomedPaneID: screen.zoomedPaneID,
                        panes: screen.panes.map { pane in
                            pane.paneID == paneID
                                ? BackendProjectionNavigationPaneState(
                                    paneID: paneID,
                                    selectedSurfaceID: surfaceID
                                )
                                : pane
                        }
                    )
                }
            }
        }
        return BackendProjectionNavigationState(
            logicalPresentationID: original.logicalPresentationID,
            generation: generation,
            claimID: original.claimID,
            claimedProcessInstanceID: original.claimedProcessInstanceID,
            reconciledTopologyRevision: topologyRevision,
            selectedWorkspaceID: selectedWorkspaceID,
            workspaces: workspaces
        )
    }
}

private func makeDriverTopology(workspaceCount: Int) throws -> CanonicalTopology {
    try CanonicalTopology(workspaces: (0 ..< workspaceCount).map { index in
        let value = UInt64(index + 1)
        let workspaceID = WorkspaceID(rawValue: driverUUID(10_000 + value))
        let screenID = ScreenID(rawValue: driverUUID(20_000 + value))
        let paneID = PaneID(rawValue: driverUUID(30_000 + value))
        let surfaceID = SurfaceID(rawValue: driverUUID(40_000 + value))
        return CanonicalWorkspace(
            id: value,
            uuid: workspaceID,
            name: "workspace-\(value)",
            screens: [
                CanonicalScreen(
                    id: value,
                    uuid: screenID,
                    name: nil,
                    layout: .leaf(pane: value, paneUUID: paneID),
                    panes: [
                        CanonicalPane(
                            id: value,
                            uuid: paneID,
                            name: nil,
                            tabs: [
                                CanonicalSurface(
                                    id: value,
                                    uuid: surfaceID,
                                    kind: "terminal",
                                    name: nil
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
    })
}

private func intentTopology() throws -> CanonicalTopology {
    let workspaceID = WorkspaceID(rawValue: driverUUID(51))
    let screenID = ScreenID(rawValue: driverUUID(52))
    let panes = (0 ..< 2).map { index -> CanonicalPane in
        let paneNumber = UInt64(index + 1)
        return CanonicalPane(
            id: paneNumber,
            uuid: PaneID(rawValue: driverUUID(60 + paneNumber)),
            name: nil,
            tabs: (0 ..< 2).map { tab in
                CanonicalSurface(
                    id: UInt64(index * 2 + tab + 1),
                    uuid: SurfaceID(rawValue: driverUUID(
                        70 + UInt64(index * 2 + tab)
                    )),
                    kind: "terminal",
                    name: nil
                )
            }
        )
    }
    return try CanonicalTopology(workspaces: [
        CanonicalWorkspace(
            id: 1,
            uuid: workspaceID,
            name: "intent",
            screens: [
                CanonicalScreen(
                    id: 1,
                    uuid: screenID,
                    name: nil,
                    layout: .split(
                        direction: .right,
                        ratio: 0.5,
                        first: .leaf(pane: panes[0].id, paneUUID: panes[0].uuid),
                        second: .leaf(pane: panes[1].id, paneUUID: panes[1].uuid)
                    ),
                    panes: panes
                ),
            ]
        ),
    ])
}

private func defaultWorkspaceState(
    _ workspace: CanonicalWorkspace
) -> BackendProjectionNavigationWorkspaceState {
    BackendProjectionNavigationWorkspaceState(
        workspaceID: workspace.uuid,
        selectedScreenID: workspace.screens[0].uuid,
        screens: workspace.screens.map { screen in
            BackendProjectionNavigationScreenState(
                screenID: screen.uuid,
                activePaneID: screen.panes[0].uuid,
                zoomedPaneID: nil,
                panes: screen.panes.map { pane in
                    BackendProjectionNavigationPaneState(
                        paneID: pane.uuid,
                        selectedSurfaceID: pane.tabs[0].uuid
                    )
                }
            )
        }
    )
}

private func mapScreen(
    _ workspaces: [BackendProjectionNavigationWorkspaceState],
    workspaceID: WorkspaceID,
    screenID: ScreenID,
    transform: (BackendProjectionNavigationScreenState)
        -> BackendProjectionNavigationScreenState
) -> [BackendProjectionNavigationWorkspaceState] {
    workspaces.map { workspace in
        guard workspace.workspaceID == workspaceID else { return workspace }
        return BackendProjectionNavigationWorkspaceState(
            workspaceID: workspace.workspaceID,
            selectedScreenID: workspace.selectedScreenID,
            screens: workspace.screens.map { screen in
                screen.screenID == screenID ? transform(screen) : screen
            }
        )
    }
}

private func driverUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", value))!
}
