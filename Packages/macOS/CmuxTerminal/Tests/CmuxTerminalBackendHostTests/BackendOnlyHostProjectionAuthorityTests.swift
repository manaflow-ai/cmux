import CmuxTerminalBackend
import CmuxTerminalBackendService
@testable import CmuxTerminalBackendHost
import Foundation
import Testing

@Suite("Backend-only host projection authority")
@MainActor
struct BackendOnlyHostProjectionAuthorityTests {
    @Test("legacy selection is deleted only after successful v2 hydration")
    func migratesLegacySelectionOnlyAfterSuccess() async throws {
        let topology = try HostProjectionFixture.topology()
        let legacyWorkspaceID = topology.workspaces[1].uuid
        let suiteName = "BackendOnlyHostProjectionAuthorityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            legacyWorkspaceID.rawValue.uuidString.lowercased(),
            forKey: "backendOnly.selectedWorkspaceID"
        )
        let failedConnection = try HostProjectionFixture.connection(
            number: 1,
            topology: topology
        )
        let failedRPC = HostProjectionFakeRPC(
            snapshot: failedConnection.initialSnapshot,
            processInstanceID: failedConnection.processInstanceID
        )
        await failedRPC.failNextClaim()
        let failedModel = BackendOnlyHostModel(
            controller: HostProjectionFakeController([
                .init(connection: failedConnection, rpc: failedRPC),
            ]),
            defaults: defaults,
            logicalPresentationID: HostProjectionFixture.uuid(900),
            maximumConnectionAttempts: 1,
            runtimeFactory: HostProjectionRuntimeFactory().makeRuntime
        )

        failedModel.start()
        await failedModel.awaitCurrentConnectionCycle()

        #expect(failedModel.phase == .unavailable)
        #expect(
            defaults.string(forKey: "backendOnly.selectedWorkspaceID")
                == legacyWorkspaceID.rawValue.uuidString.lowercased()
        )

        let successfulConnection = try HostProjectionFixture.connection(
            number: 2,
            topology: topology
        )
        let successfulRPC = HostProjectionFakeRPC(
            snapshot: successfulConnection.initialSnapshot,
            processInstanceID: successfulConnection.processInstanceID
        )
        let successfulModel = BackendOnlyHostModel(
            controller: HostProjectionFakeController([
                .init(connection: successfulConnection, rpc: successfulRPC),
            ]),
            defaults: defaults,
            logicalPresentationID: HostProjectionFixture.uuid(900),
            maximumConnectionAttempts: 1,
            runtimeFactory: HostProjectionRuntimeFactory().makeRuntime
        )

        successfulModel.start()
        await successfulModel.awaitCurrentConnectionCycle()
        await successfulModel.awaitProjectionPersistence()

        #expect(successfulModel.phase == .ready)
        #expect(successfulModel.selectedWorkspaceID == legacyWorkspaceID.rawValue)
        #expect(defaults.object(forKey: "backendOnly.selectedWorkspaceID") == nil)
    }

    @Test("one immutable plan publishes terminals and native placeholders")
    func publishesMultiPanePlanAtomically() async throws {
        let topology = try HostProjectionFixture.topology()
        let connection = try HostProjectionFixture.connection(
            number: 1,
            topology: topology
        )
        let rpc = HostProjectionFakeRPC(
            snapshot: connection.initialSnapshot,
            processInstanceID: connection.processInstanceID
        )
        let factory = HostProjectionRuntimeFactory()
        let model = makeModel(
            connection: connection,
            rpc: rpc,
            logicalPresentationID: HostProjectionFixture.uuid(901),
            legacyWorkspaceID: topology.workspaces[1].uuid,
            runtimeFactory: factory
        )

        model.start()
        await model.awaitCurrentConnectionCycle()
        await model.awaitProjectionPersistence()

        let snapshot = try #require(model.runtimeSnapshot)
        #expect(snapshot.plan.workspaceID == topology.workspaces[1].uuid)
        #expect(snapshot.plan.panes.count == 3)
        #expect(snapshot.slots.count == 3)
        #expect(snapshot.slots.compactMap(\.runtime).count == 1)
        #expect(factory.creationCount == 1)
        #expect(snapshot.plan.panes.contains {
            if case .browserPlaceholder = $0.content { return true }
            return false
        })
        #expect(snapshot.plan.panes.contains {
            if case .unsupportedPlaceholder = $0.content { return true }
            return false
        })
    }

    @Test("screen pane zoom and tab actions are absolute v2 intents")
    func submitsAbsoluteNavigationActions() async throws {
        let topology = try HostProjectionFixture.topology()
        let workspace = topology.workspaces[1]
        let firstScreen = workspace.screens[0]
        let secondScreen = workspace.screens[1]
        let terminalPane = firstScreen.panes[0]
        let browserPane = firstScreen.panes[1]
        let secondTerminalSurface = terminalPane.tabs[1]
        let connection = try HostProjectionFixture.connection(
            number: 1,
            topology: topology
        )
        let rpc = HostProjectionFakeRPC(
            snapshot: connection.initialSnapshot,
            processInstanceID: connection.processInstanceID
        )
        let model = makeModel(
            connection: connection,
            rpc: rpc,
            logicalPresentationID: HostProjectionFixture.uuid(902),
            legacyWorkspaceID: workspace.uuid
        )

        model.start()
        await model.awaitCurrentConnectionCycle()
        await rpc.clearMutationLog()

        model.selectScreen(
            workspaceID: workspace.uuid.rawValue,
            screenID: secondScreen.uuid.rawValue
        )
        model.selectScreen(
            workspaceID: workspace.uuid.rawValue,
            screenID: firstScreen.uuid.rawValue
        )
        model.activatePane(
            workspaceID: workspace.uuid.rawValue,
            screenID: firstScreen.uuid.rawValue,
            paneID: browserPane.uuid.rawValue
        )
        model.setZoomedPane(
            workspaceID: workspace.uuid.rawValue,
            screenID: firstScreen.uuid.rawValue,
            paneID: browserPane.uuid.rawValue
        )
        model.selectSurface(
            workspaceID: workspace.uuid.rawValue,
            screenID: firstScreen.uuid.rawValue,
            paneID: terminalPane.uuid.rawValue,
            surfaceID: secondTerminalSurface.uuid.rawValue
        )
        await model.awaitProjectionPersistence()

        let snapshot = try #require(model.runtimeSnapshot)
        #expect(snapshot.plan.screenID == firstScreen.uuid)
        #expect(snapshot.plan.activePaneID == browserPane.uuid)
        #expect(snapshot.plan.zoomedPaneID == browserPane.uuid)
        #expect(snapshot.plan.panes.count == 1)
        let operations = await rpc.mutationOperations().flatMap { $0 }
        #expect(operations.contains(.selectScreen(
            workspaceID: workspace.uuid,
            screenID: firstScreen.uuid
        )))
        #expect(operations.contains(.activatePane(
            workspaceID: workspace.uuid,
            screenID: firstScreen.uuid,
            paneID: browserPane.uuid
        )))
        #expect(operations.contains(.setZoomedPane(
            workspaceID: workspace.uuid,
            screenID: firstScreen.uuid,
            paneID: browserPane.uuid
        )))
        #expect(operations.contains(.selectSurface(
            workspaceID: workspace.uuid,
            screenID: firstScreen.uuid,
            paneID: terminalPane.uuid,
            surfaceID: secondTerminalSurface.uuid
        )))
    }

    @Test("claim loss clears publication and never reclaims")
    func claimLossIsTerminal() async throws {
        let topology = try HostProjectionFixture.topology()
        let connection = try HostProjectionFixture.connection(
            number: 1,
            topology: topology
        )
        let rpc = HostProjectionFakeRPC(
            snapshot: connection.initialSnapshot,
            processInstanceID: connection.processInstanceID
        )
        let model = makeModel(
            connection: connection,
            rpc: rpc,
            logicalPresentationID: HostProjectionFixture.uuid(903)
        )

        model.start()
        await model.awaitCurrentConnectionCycle()
        await rpc.loseNextMutationClaim()
        model.selectWorkspace(topology.workspaces[1].uuid.rawValue)
        await model.awaitProjectionPersistence()

        #expect(model.phase == .unavailable)
        #expect(model.runtimeSnapshot == nil)
        #expect(await rpc.claimCount == 1)
    }

    @Test("disconnect signal advances generation and stale events cannot republish")
    func reconnectRejectsStaleEvents() async throws {
        let topology = try HostProjectionFixture.topology()
        let first = try HostProjectionFixture.connection(number: 1, topology: topology)
        let second = try HostProjectionFixture.connection(number: 2, topology: topology)
        let firstRPC = HostProjectionFakeRPC(
            snapshot: first.initialSnapshot,
            processInstanceID: first.processInstanceID
        )
        let secondRPC = HostProjectionFakeRPC(
            snapshot: second.initialSnapshot,
            processInstanceID: second.processInstanceID
        )
        let controller = HostProjectionFakeController([
            .init(connection: first, rpc: firstRPC),
            .init(connection: second, rpc: secondRPC),
        ])
        let model = BackendOnlyHostModel(
            controller: controller,
            defaults: isolatedDefaults(),
            logicalPresentationID: HostProjectionFixture.uuid(904),
            maximumConnectionAttempts: 1,
            runtimeFactory: HostProjectionRuntimeFactory().makeRuntime
        )

        model.start()
        await model.awaitCurrentConnectionCycle()
        let firstPublication = try #require(model.runtimeSnapshot)
        let retained = try #require(await firstRPC.record)
        await secondRPC.install(record: retained)

        await controller.disconnect(connectionNumber: 1)
        await controller.waitForConnectAttempt(2)
        await model.awaitCurrentConnectionCycle()
        await model.awaitProjectionPersistence()

        let secondPublication = try #require(model.runtimeSnapshot)
        #expect(firstPublication.fence.connectionGeneration == 1)
        #expect(secondPublication.fence.connectionGeneration == 2)
        await controller.emitStaleSnapshot(connectionNumber: 1)
        await model.awaitProjectionPersistence()
        #expect(model.runtimeSnapshot?.fence == secondPublication.fence)
    }

    @Test("rapid topology and actions share one latest-only refresh lane")
    func rapidTopologyAndActionsAreBounded() async throws {
        let topology = try HostProjectionFixture.topology()
        let connection = try HostProjectionFixture.connection(number: 1, topology: topology)
        let rpc = HostProjectionFakeRPC(
            snapshot: connection.initialSnapshot,
            processInstanceID: connection.processInstanceID
        )
        let controller = HostProjectionFakeController([
            .init(connection: connection, rpc: rpc),
        ])
        let model = BackendOnlyHostModel(
            controller: controller,
            defaults: isolatedDefaults(),
            logicalPresentationID: HostProjectionFixture.uuid(905),
            maximumConnectionAttempts: 1,
            runtimeFactory: HostProjectionRuntimeFactory().makeRuntime
        )
        model.start()
        await model.awaitCurrentConnectionCycle()

        for revision in 2 ... 64 {
            let snapshot = TopologySnapshot(
                authority: connection.initialSnapshot.authority,
                revision: UInt64(revision),
                topology: topology
            )
            await rpc.install(snapshot: snapshot)
            await controller.install(snapshot: snapshot, connectionNumber: 1)
            await controller.emitTopologyEvent(connectionNumber: 1)
            model.selectWorkspace(
                topology.workspaces[revision.isMultiple(of: 2) ? 0 : 1]
                    .uuid.rawValue
            )
        }
        model.selectWorkspace(topology.workspaces[1].uuid.rawValue)
        await model.awaitProjectionPersistence()

        #expect(model.runtimeSnapshot?.fence.topologyRevision == 64)
        #expect(model.selectedWorkspaceID == topology.workspaces[1].uuid.rawValue)
        #expect(model.maximumPendingProjectionRefreshCountObserved == 1)
        #expect(await rpc.maximumRPCsInFlight == 1)
    }

    private func makeModel(
        connection: BackendOnlyHostConnection,
        rpc: HostProjectionFakeRPC,
        logicalPresentationID: UUID,
        legacyWorkspaceID: WorkspaceID? = nil,
        runtimeFactory: HostProjectionRuntimeFactory = HostProjectionRuntimeFactory()
    ) -> BackendOnlyHostModel {
        let defaults = isolatedDefaults()
        if let legacyWorkspaceID {
            defaults.set(
                legacyWorkspaceID.rawValue.uuidString.lowercased(),
                forKey: "backendOnly.selectedWorkspaceID"
            )
        }
        return BackendOnlyHostModel(
            controller: HostProjectionFakeController([
                .init(connection: connection, rpc: rpc),
            ]),
            defaults: defaults,
            logicalPresentationID: logicalPresentationID,
            maximumConnectionAttempts: 1,
            runtimeFactory: runtimeFactory.makeRuntime
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "BackendOnlyHostProjectionAuthorityTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class HostProjectionRuntimeFactory {
    @MainActor
    private final class Runtime: BackendOnlyHostRuntimeLifecycle {
        let selection: BackendOnlyTerminalSelection

        init(selection: BackendOnlyTerminalSelection) {
            self.selection = selection
        }

        func shutdown() async {}
    }

    private(set) var creationCount = 0

    func makeRuntime(
        session: BackendCanonicalSession,
        selection: BackendOnlyTerminalSelection
    ) -> any BackendOnlyHostRuntimeLifecycle {
        _ = session
        creationCount += 1
        return Runtime(selection: selection)
    }
}

private actor HostProjectionFakeController: BackendOnlyHostSessionControlling {
    struct Candidate: Sendable {
        let connection: BackendOnlyHostConnection
        let rpc: HostProjectionFakeRPC
    }

    private enum Failure: Error { case exhausted }

    private var candidates: [Candidate]
    private var attempts = 0
    private var rpcBySession: [ObjectIdentifier: HostProjectionFakeRPC] = [:]
    private var snapshots: [Int: TopologySnapshot] = [:]
    private var eventContinuations: [
        Int: AsyncStream<BackendCanonicalSessionEvent>.Continuation
    ] = [:]
    private var attemptWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(_ candidates: [Candidate]) {
        self.candidates = candidates
        for candidate in candidates {
            rpcBySession[ObjectIdentifier(candidate.connection.session)] = candidate.rpc
            if let number = Self.number(candidate.connection) {
                snapshots[number] = candidate.connection.initialSnapshot
            }
        }
    }

    func connect() async throws -> BackendOnlyHostConnection {
        attempts += 1
        for waiter in attemptWaiters.removeValue(forKey: attempts) ?? [] {
            waiter.resume()
        }
        guard !candidates.isEmpty else { throw Failure.exhausted }
        return candidates.removeFirst().connection
    }

    func projectionRPC(
        for connection: BackendOnlyHostConnection
    ) async throws -> any BackendOnlyProjectionDriverRPC {
        guard let rpc = rpcBySession[ObjectIdentifier(connection.session)] else {
            throw Failure.exhausted
        }
        return rpc
    }

    func events(
        for connection: BackendOnlyHostConnection
    ) async -> AsyncStream<BackendCanonicalSessionEvent> {
        let pair = AsyncStream<BackendCanonicalSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        if let number = Self.number(connection) {
            eventContinuations[number] = pair.continuation
        }
        return pair.stream
    }

    func currentSnapshot(
        for connection: BackendOnlyHostConnection
    ) async -> TopologySnapshot? {
        guard let number = Self.number(connection) else { return nil }
        return snapshots[number]
    }

    func invalidate(_ connection: BackendOnlyHostConnection) async {}

    func disconnect(connectionNumber: Int) {
        eventContinuations[connectionNumber]?.yield(
            .disconnected(.topologyStreamFailed("test disconnect"))
        )
    }

    func emitTopologyEvent(connectionNumber: Int) {
        eventContinuations[connectionNumber]?.yield(.snapshot)
    }

    func emitStaleSnapshot(connectionNumber: Int) {
        eventContinuations[connectionNumber]?.yield(.snapshot)
    }

    func install(snapshot: TopologySnapshot, connectionNumber: Int) {
        snapshots[connectionNumber] = snapshot
    }

    func waitForConnectAttempt(_ count: Int) async {
        guard attempts < count else { return }
        await withCheckedContinuation { continuation in
            attemptWaiters[count, default: []].append(continuation)
        }
    }

    private static func number(_ connection: BackendOnlyHostConnection) -> Int? {
        Int(connection.readiness.session.split(separator: "-").last ?? "")
    }
}

private actor HostProjectionFakeRPC: BackendOnlyProjectionDriverRPC {
    private enum Failure: Error { case injected }

    private var snapshot: TopologySnapshot
    private let processInstanceID: UUID
    private var storedRecord: BackendProjectionNavigationState?
    private var shouldFailClaim = false
    private var shouldLoseClaim = false
    private var claims = 0
    private var mutationLog: [[BackendProjectionNavigationOperation]] = []
    private var rpcsInFlight = 0
    private(set) var maximumRPCsInFlight = 0

    init(snapshot: TopologySnapshot, processInstanceID: UUID) {
        self.snapshot = snapshot
        self.processInstanceID = processInstanceID
    }

    var record: BackendProjectionNavigationState? { storedRecord }
    var claimCount: Int { claims }

    func failNextClaim() { shouldFailClaim = true }
    func loseNextMutationClaim() { shouldLoseClaim = true }
    func clearMutationLog() { mutationLog.removeAll() }
    func mutationOperations() -> [[BackendProjectionNavigationOperation]] { mutationLog }

    func install(record: BackendProjectionNavigationState) {
        storedRecord = BackendProjectionNavigationState(
            logicalPresentationID: record.logicalPresentationID,
            generation: record.generation,
            claimID: nil,
            claimedProcessInstanceID: nil,
            reconciledTopologyRevision: snapshot.revision,
            selectedWorkspaceID: record.selectedWorkspaceID,
            workspaces: record.workspaces
        )
    }

    func install(snapshot: TopologySnapshot) {
        self.snapshot = snapshot
        if let record = storedRecord {
            storedRecord = copy(
                record,
                reconciledTopologyRevision: snapshot.revision
            )
        }
    }

    func listAllProjectionNavigationV2(
        authority: BackendAuthority,
        expectedTopologyRevision: UInt64
    ) async throws -> BackendProjectionNavigationResponse {
        try begin(authority: authority, revision: expectedTopologyRevision)
        defer { end() }
        return applied(storedRecord.map { [$0] } ?? [])
    }

    func claimProjectionNavigationV2(
        logicalPresentationID: UUID,
        authority: BackendAuthority,
        expectedTopologyRevision: UInt64
    ) async throws -> BackendProjectionNavigationResponse {
        try begin(authority: authority, revision: expectedTopologyRevision)
        defer { end() }
        if shouldFailClaim {
            shouldFailClaim = false
            throw Failure.injected
        }
        claims += 1
        let previous = storedRecord
        let claimed = BackendProjectionNavigationState(
            logicalPresentationID: logicalPresentationID,
            generation: (previous?.generation ?? 0) + 1,
            claimID: UUID(),
            claimedProcessInstanceID: processInstanceID,
            reconciledTopologyRevision: snapshot.revision,
            selectedWorkspaceID: previous?.selectedWorkspaceID,
            workspaces: previous?.workspaces ?? []
        )
        storedRecord = claimed
        return applied([claimed])
    }

    func mutateProjectionNavigationV2(
        requestID: UUID,
        authority: BackendAuthority,
        expectedTopologyRevision: UInt64,
        projections: [BackendProjectionNavigationMutation]
    ) async throws -> BackendProjectionNavigationResponse {
        _ = requestID
        try begin(authority: authority, revision: expectedTopologyRevision)
        defer { end() }
        guard let mutation = projections.first,
              let current = storedRecord
        else { throw Failure.injected }
        mutationLog.append(mutation.operations)
        if shouldLoseClaim {
            shouldLoseClaim = false
            return .conflict(.claimLost(
                logicalPresentationID: mutation.logicalPresentationID,
                claimedProcessInstanceID: HostProjectionFixture.uuid(999)
            ))
        }
        guard mutation.claimID == current.claimID,
              mutation.expectedGeneration == current.generation
        else {
            return .conflict(.staleGeneration(
                logicalPresentationID: mutation.logicalPresentationID,
                expected: mutation.expectedGeneration,
                current: current.generation,
                currentState: current
            ))
        }
        var updated = current
        for operation in mutation.operations {
            updated = apply(operation, to: updated)
        }
        updated = copy(updated, generation: current.generation + 1)
        storedRecord = updated
        return applied([updated])
    }

    private func begin(
        authority: BackendAuthority,
        revision: UInt64
    ) throws {
        guard authority == snapshot.authority, revision == snapshot.revision else {
            throw Failure.injected
        }
        rpcsInFlight += 1
        maximumRPCsInFlight = max(maximumRPCsInFlight, rpcsInFlight)
    }

    private func end() { rpcsInFlight -= 1 }

    private func applied(
        _ states: [BackendProjectionNavigationState]
    ) -> BackendProjectionNavigationResponse {
        .applied(BackendProjectionNavigationApplied(
            topologyRevision: snapshot.revision,
            clientRevision: 1,
            states: states
        ))
    }

    private func apply(
        _ operation: BackendProjectionNavigationOperation,
        to state: BackendProjectionNavigationState
    ) -> BackendProjectionNavigationState {
        var workspaces = state.workspaces
        var selectedWorkspaceID = state.selectedWorkspaceID
        switch operation {
        case .assignWorkspace(let workspaceID):
            if !workspaces.contains(where: { $0.workspaceID == workspaceID }),
               let workspace = snapshot.topology.workspaces.first(
                where: { $0.uuid == workspaceID }
               ) {
                workspaces.append(navigation(workspace))
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
            workspaces = mapScreen(workspaces, workspaceID, screenID) { screen in
                BackendProjectionNavigationScreenState(
                    screenID: screen.screenID,
                    activePaneID: paneID,
                    zoomedPaneID: screen.zoomedPaneID == paneID
                        ? screen.zoomedPaneID : nil,
                    panes: screen.panes
                )
            }
        case .setZoomedPane(let workspaceID, let screenID, let paneID):
            workspaces = mapScreen(workspaces, workspaceID, screenID) { screen in
                BackendProjectionNavigationScreenState(
                    screenID: screen.screenID,
                    activePaneID: paneID ?? screen.activePaneID,
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
            workspaces = mapScreen(workspaces, workspaceID, screenID) { screen in
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
        return BackendProjectionNavigationState(
            logicalPresentationID: state.logicalPresentationID,
            generation: state.generation,
            claimID: state.claimID,
            claimedProcessInstanceID: state.claimedProcessInstanceID,
            reconciledTopologyRevision: snapshot.revision,
            selectedWorkspaceID: selectedWorkspaceID,
            workspaces: workspaces
        )
    }

    private func mapScreen(
        _ workspaces: [BackendProjectionNavigationWorkspaceState],
        _ workspaceID: WorkspaceID,
        _ screenID: ScreenID,
        transform: (BackendProjectionNavigationScreenState)
            -> BackendProjectionNavigationScreenState
    ) -> [BackendProjectionNavigationWorkspaceState] {
        workspaces.map { workspace in
            guard workspace.workspaceID == workspaceID else { return workspace }
            return BackendProjectionNavigationWorkspaceState(
                workspaceID: workspace.workspaceID,
                selectedScreenID: workspace.selectedScreenID,
                screens: workspace.screens.map {
                    $0.screenID == screenID ? transform($0) : $0
                }
            )
        }
    }

    private func navigation(
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

    private func copy(
        _ state: BackendProjectionNavigationState,
        generation: UInt64? = nil,
        reconciledTopologyRevision: UInt64? = nil
    ) -> BackendProjectionNavigationState {
        BackendProjectionNavigationState(
            logicalPresentationID: state.logicalPresentationID,
            generation: generation ?? state.generation,
            claimID: state.claimID,
            claimedProcessInstanceID: state.claimedProcessInstanceID,
            reconciledTopologyRevision: reconciledTopologyRevision
                ?? state.reconciledTopologyRevision,
            selectedWorkspaceID: state.selectedWorkspaceID,
            workspaces: state.workspaces
        )
    }
}

private enum HostProjectionFixture {
    static func topology() throws -> CanonicalTopology {
        let simple = workspace(1, paneKinds: [["terminal"]])
        let terminalPane = pane(220, kinds: ["terminal", "terminal"])
        let browserPane = pane(230, kinds: ["browser"])
        let unsupportedPane = pane(240, kinds: ["editor"])
        let firstScreen = CanonicalScreen(
            id: 210,
            uuid: ScreenID(rawValue: uuid(210)),
            name: "split",
            layout: .split(
                direction: .right,
                ratio: 0.5,
                first: .leaf(pane: terminalPane.id, paneUUID: terminalPane.uuid),
                second: .split(
                    direction: .down,
                    ratio: 0.5,
                    first: .leaf(pane: browserPane.id, paneUUID: browserPane.uuid),
                    second: .leaf(
                        pane: unsupportedPane.id,
                        paneUUID: unsupportedPane.uuid
                    )
                )
            ),
            panes: [terminalPane, browserPane, unsupportedPane]
        )
        let secondPane = pane(260, kinds: ["terminal"])
        let secondScreen = CanonicalScreen(
            id: 250,
            uuid: ScreenID(rawValue: uuid(250)),
            name: "second",
            layout: .leaf(pane: secondPane.id, paneUUID: secondPane.uuid),
            panes: [secondPane]
        )
        let split = CanonicalWorkspace(
            id: 200,
            uuid: WorkspaceID(rawValue: uuid(200)),
            name: "split workspace",
            screens: [firstScreen, secondScreen]
        )
        return try CanonicalTopology(workspaces: [simple, split])
    }

    static func connection(
        number: Int,
        topology: CanonicalTopology
    ) throws -> BackendOnlyHostConnection {
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: uuid(10_000)),
            sessionID: SessionID(rawValue: uuid(10_001))
        )
        let peerIdentity = BackendPeerIdentity(
            processID: UInt32(20_000 + number),
            userID: 501,
            auditToken: BackendAuditToken(
                word0: UInt32(number), word1: 0, word2: 0, word3: 0,
                word4: 0, word5: 0, word6: 0, word7: 0
            )
        )
        let readiness = BackendServiceReadiness(
            authority: authority,
            session: "test-\(number)",
            processID: peerIdentity.processID,
            userID: peerIdentity.userID,
            peerIdentity: peerIdentity,
            peerTrust: BackendPeerTrustEvidence(
                signingIdentifier: "com.cmux.test.backend",
                teamIdentifier: nil,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                processIDVersion: Int32(number)
            ),
            topologyRevision: 1,
            compatibility: .readWrite(BackendReadWriteCompatibility(
                clientProtocolRange: 9 ... 9,
                serverProtocolRange: 9 ... 9,
                negotiatedProtocol: 9,
                requiredCapabilities: []
            ))
        )
        let stableClientID = uuid(30_000)
        let processInstanceID = uuid(UInt64(31_000 + number))
        let registration = try #require(BackendClientRegistrationIdentity(
            clientUUID: stableClientID,
            processInstanceUUID: processInstanceID
        ))
        let session = BackendCanonicalSession(
            transport: HostProjectionInertTransport(),
            expectation: BackendCanonicalSessionExpectation(session: readiness.session),
            registrationIdentity: registration
        )
        return BackendOnlyHostConnection(
            session: session,
            readiness: readiness,
            initialSnapshot: TopologySnapshot(
                authority: authority,
                revision: 1,
                topology: topology
            ),
            stableClientID: stableClientID,
            processInstanceID: processInstanceID
        )
    }

    static func uuid(_ value: UInt64) -> UUID {
        let suffix = String(format: "%012llx", value)
        return UUID(uuidString: "11111111-1111-4111-8111-\(suffix)")!
    }

    private static func workspace(
        _ id: UInt64,
        paneKinds: [[String]]
    ) -> CanonicalWorkspace {
        let panes = paneKinds.enumerated().map { offset, kinds in
            pane(id * 100 + UInt64(offset + 2), kinds: kinds)
        }
        let screen = CanonicalScreen(
            id: id * 100 + 1,
            uuid: ScreenID(rawValue: uuid(id * 100 + 1)),
            name: nil,
            layout: .leaf(pane: panes[0].id, paneUUID: panes[0].uuid),
            panes: panes
        )
        return CanonicalWorkspace(
            id: id,
            uuid: WorkspaceID(rawValue: uuid(id)),
            name: "workspace \(id)",
            screens: [screen]
        )
    }

    private static func pane(_ id: UInt64, kinds: [String]) -> CanonicalPane {
        CanonicalPane(
            id: id,
            uuid: PaneID(rawValue: uuid(id)),
            name: nil,
            tabs: kinds.enumerated().map { offset, kind in
                CanonicalSurface(
                    id: id * 100 + UInt64(offset + 1),
                    uuid: SurfaceID(rawValue: uuid(id * 100 + UInt64(offset + 1))),
                    kind: kind,
                    name: nil
                )
            }
        )
    }
}

private actor HostProjectionInertTransport: BackendPeerIdentityTransport {
    private enum Failure: Error { case unavailable }
    func connect() async throws { throw Failure.unavailable }
    func send(_ message: Data) async throws { throw Failure.unavailable }
    func receive() async throws -> Data { throw Failure.unavailable }
    func peerIdentity() async throws -> BackendPeerIdentity { throw Failure.unavailable }
    func close() async {}
}
