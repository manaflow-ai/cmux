public import CmuxTerminalBackend
public import Foundation
public import SwiftUI
internal import Observation

extension BackendOnlyTerminalRuntime: BackendOnlyHostRuntimeLifecycle {}

typealias BackendOnlyHostRuntimeFactory = @MainActor (
    BackendCanonicalSession,
    BackendOnlyTerminalSelection
) -> any BackendOnlyHostRuntimeLifecycle

/// Observable state for the backend-only host application.
@Observable
@MainActor
public final class BackendOnlyHostModel {
    /// The connection phase exposed under the original nested name.
    public typealias Phase = BackendOnlyHostPhase

    /// The current backend connection phase.
    public private(set) var phase: Phase = .connecting
    private var publishedProjection: BackendOnlyHostPublishedProjection?
    /// The latest projection failure, for host diagnostics.
    public private(set) var lastProjectionFailureDescription: String?

    /// The latest canonical topology.
    public var topology: CanonicalTopology? {
        publishedProjection?.authority.topology
    }

    /// The selected workspace identifier.
    public var selectedWorkspaceID: UUID? {
        publishedProjection?.authority.navigation.selectedWorkspaceID?.rawValue
    }

    /// The runtime for the canonical active terminal slot.
    public var activeRuntime: BackendOnlyTerminalRuntime? {
        guard let runtime = publishedProjection?.runtime,
              let slot = runtime.slots.first(where: {
                  $0.slotID == runtime.activeSlotID
              })
        else { return nil }
        return slot.runtime as? BackendOnlyTerminalRuntime
    }

    var runtimeSnapshot: BackendOnlyProjectionRuntimeSnapshot? {
        publishedProjection?.runtime
    }

    /// Workspaces assigned to this frontend presentation.
    public var workspaces: [CanonicalWorkspace] {
        guard let projection = publishedProjection else { return [] }
        let assigned = Set(
            projection.authority.navigation.workspaces.map(\.workspaceID)
        )
        return projection.authority.topology.workspaces.filter {
            assigned.contains($0.uuid)
        }
    }

    private static let logicalPresentationDefaultsKey =
        "backendOnly.logicalPresentationID"
    private static let selectedWorkspaceDefaultsKey =
        "backendOnly.selectedWorkspaceID"
    private static let defaultMaximumConnectionAttempts = 3
    private static let maximumPendingIntentCount = 4096

    private let controller: (any BackendOnlyHostSessionControlling)?
    private let defaults: UserDefaults
    private let logicalPresentationID: UUID
    private let maximumConnectionAttempts: Int
    private let legacySelectedWorkspaceSeed: WorkspaceID?
    private let runtimeReconciler: BackendOnlyProjectionRuntimeReconciler
    private let projectionPlanner = BackendOnlyProjectionPlanner()

    private var legacyMigrationPending: Bool
    private var connection: BackendOnlyHostConnection?
    private var currentConnectionGeneration: UInt64?
    private var nextConnectionGeneration: UInt64 = 1
    private var projectionDriver: BackendOnlyProjectionDriver?
    private var eventTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var connectionCycleID: UUID?
    private var projectionLaneTask: Task<Void, Never>?
    private var projectionLaneID: UUID?
    private var pendingTopologySnapshot: TopologySnapshot?
    private var pendingRepublish = false
    private var pendingIntents: [BackendOnlyHostProjectionIntentKey: BackendOnlyHostPendingIntent] = [:]
    private var nextIntentSequence: UInt64 = 1
    private var workspaceMutationTask: Task<Void, Never>?
    private(set) var maximumPendingProjectionRefreshCountObserved = 0

    /// Creates a host model from the current app bundle and user defaults.
    public convenience init(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard
    ) {
        self.init(
            controller: BackendOnlySessionController(
                bundleURL: bundleURL,
                bundleIdentifier: bundleIdentifier,
                homeDirectoryURL: backendOnlyCurrentHomeDirectoryURL()
            ),
            defaults: defaults,
            logicalPresentationID: nil,
            maximumConnectionAttempts: Self.defaultMaximumConnectionAttempts
        )
    }

    init(
        controller: (any BackendOnlyHostSessionControlling)?,
        defaults: UserDefaults,
        logicalPresentationID: UUID?,
        maximumConnectionAttempts: Int,
        runtimeFactory: BackendOnlyHostRuntimeFactory? = nil
    ) {
        precondition(maximumConnectionAttempts > 0)
        self.controller = controller
        self.defaults = defaults
        self.maximumConnectionAttempts = maximumConnectionAttempts
        let makeRuntime = runtimeFactory ?? { session, selection in
            BackendOnlyTerminalRuntime(session: session, selection: selection)
        }
        runtimeReconciler = BackendOnlyProjectionRuntimeReconciler {
            session, selection in
            makeRuntime(session, selection)
        }

        if let logicalPresentationID {
            self.logicalPresentationID = logicalPresentationID
        } else if let stored = defaults.string(
            forKey: Self.logicalPresentationDefaultsKey
        ), let value = UUID(uuidString: stored) {
            self.logicalPresentationID = value
        } else {
            let value = UUID()
            self.logicalPresentationID = value
            defaults.set(
                value.uuidString.lowercased(),
                forKey: Self.logicalPresentationDefaultsKey
            )
        }

        legacyMigrationPending = defaults.object(
            forKey: Self.selectedWorkspaceDefaultsKey
        ) != nil
        if let stored = defaults.string(
            forKey: Self.selectedWorkspaceDefaultsKey
        ), let value = UUID(uuidString: stored) {
            legacySelectedWorkspaceSeed = WorkspaceID(rawValue: value)
        } else {
            legacySelectedWorkspaceSeed = nil
        }
        pendingIntents.reserveCapacity(Self.maximumPendingIntentCount)
    }

    deinit {
        eventTask?.cancel()
        connectTask?.cancel()
        projectionLaneTask?.cancel()
        workspaceMutationTask?.cancel()
    }

    /// Starts the backend connection cycle if it is idle.
    public func start() {
        scheduleConnectionCycle()
    }

    func awaitCurrentConnectionCycle() async {
        let task = connectTask
        await task?.value
    }

    func awaitProjectionPersistence() async {
        while let task = projectionLaneTask {
            await task.value
        }
    }

    /// Selects one assigned workspace.
    public func selectWorkspace(_ identifier: UUID?) {
        enqueueProjectionIntents([
            .selectWorkspace(
                workspaceID: identifier.map { WorkspaceID(rawValue: $0) }
            ),
        ])
    }

    /// Assigns or removes a workspace from this presentation.
    public func setWorkspaceAssigned(_ identifier: UUID, assigned: Bool) {
        enqueueProjectionIntents([
            .workspaceAssignment(
                workspaceID: WorkspaceID(rawValue: identifier),
                assigned: assigned
            ),
        ])
    }

    /// Selects a screen in the given workspace.
    public func selectScreen(workspaceID: UUID, screenID: UUID) {
        enqueueProjectionIntents([
            .selectScreen(
                workspaceID: WorkspaceID(rawValue: workspaceID),
                screenID: ScreenID(rawValue: screenID)
            ),
        ])
    }

    /// Activates a pane in the given screen.
    public func activatePane(
        workspaceID: UUID,
        screenID: UUID,
        paneID: UUID
    ) {
        enqueueProjectionIntents([
            .activatePane(
                workspaceID: WorkspaceID(rawValue: workspaceID),
                screenID: ScreenID(rawValue: screenID),
                paneID: PaneID(rawValue: paneID)
            ),
        ])
    }

    /// Sets or clears the zoomed pane in the given screen.
    public func setZoomedPane(
        workspaceID: UUID,
        screenID: UUID,
        paneID: UUID?
    ) {
        let workspaceID = WorkspaceID(rawValue: workspaceID)
        let screenID = ScreenID(rawValue: screenID)
        let paneID = paneID.map { PaneID(rawValue: $0) }
        var intents: [BackendOnlyProjectionAbsoluteIntent] = []
        if let paneID {
            intents.append(.activatePane(
                workspaceID: workspaceID,
                screenID: screenID,
                paneID: paneID
            ))
        }
        intents.append(.setZoomedPane(
            workspaceID: workspaceID,
            screenID: screenID,
            paneID: paneID
        ))
        enqueueProjectionIntents(intents)
    }

    /// Selects a surface in the given pane.
    public func selectSurface(
        workspaceID: UUID,
        screenID: UUID,
        paneID: UUID,
        surfaceID: UUID
    ) {
        enqueueProjectionIntents([
            .selectSurface(
                workspaceID: WorkspaceID(rawValue: workspaceID),
                screenID: ScreenID(rawValue: screenID),
                paneID: PaneID(rawValue: paneID),
                surfaceID: SurfaceID(rawValue: surfaceID)
            ),
        ])
    }

    /// Creates and selects a new canonical workspace.
    public func createWorkspace() {
        guard workspaceMutationTask == nil, let connection else { return }
        workspaceMutationTask = Task { @MainActor [weak self] in
            defer { self?.workspaceMutationTask = nil }
            guard let self else { return }
            do {
                guard let snapshot = await connection.session.currentSnapshot(),
                      self.isCurrent(connection)
                else { return }
                let workspaceID = WorkspaceID(rawValue: UUID())
                let surfaceID = SurfaceID(rawValue: UUID())
                let expectation = try await connection.session
                    .makeTopologyMutationExpectation(
                        requestID: UUID(),
                        authority: snapshot.authority,
                        revision: snapshot.revision
                    )
                guard self.isCurrent(connection) else { return }
                _ = try await connection.session.newWorkspace(
                    expectation: expectation,
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    name: BackendOnlyLocalization.string(
                        "backendOnly.workspace.fallback",
                        defaultValue: "Workspace"
                    ),
                    columns: 100,
                    rows: 30
                )
                guard let updated = await connection.session.currentSnapshot(),
                      self.isCurrent(connection)
                else { return }
                self.enqueueTopology(updated)
                self.enqueueProjectionIntents([
                    .selectWorkspace(workspaceID: workspaceID),
                ])
            } catch {
                guard self.isCurrent(connection) else { return }
                self.recordFailure(error)
            }
        }
    }

    private func scheduleConnectionCycle() {
        guard connectTask == nil, connection == nil else { return }
        guard let controller else {
            phase = .unavailable
            return
        }
        phase = .connecting
        let cycleID = UUID()
        connectionCycleID = cycleID
        connectTask = Task { @MainActor [weak self, controller] in
            await self?.runConnectionCycle(
                controller: controller,
                cycleID: cycleID
            )
        }
    }

    private func runConnectionCycle(
        controller: any BackendOnlyHostSessionControlling,
        cycleID: UUID
    ) async {
        defer { finishConnectionCycle(cycleID) }

        for attempt in 1 ... maximumConnectionAttempts {
            var candidate: BackendOnlyHostConnection?
            do {
                let connected = try await controller.connect()
                candidate = connected
                let rpc = try await controller.projectionRPC(for: connected)
                guard let exactSnapshot = await controller.currentSnapshot(
                    for: connected
                ) else {
                    throw BackendCanonicalSessionError.notConnected
                }
                let connectionGeneration = try allocateConnectionGeneration()
                let driver = try await prepareDriver(
                    rpc: rpc,
                    connection: connected,
                    snapshot: exactSnapshot,
                    connectionGeneration: connectionGeneration
                )
                await driver.waitUntilIdle()
                guard let publication = await driver.publication else {
                    throw BackendOnlyProjectionDriverError.protocolFenceMismatch
                }
                try Task.checkCancellation()
                guard connectionCycleID == cycleID, connection == nil else {
                    await controller.invalidate(connected)
                    return
                }

                connection = connected
                currentConnectionGeneration = connectionGeneration
                try await materializeAndPublish(
                    connection: connected,
                    driver: driver,
                    publication: publication
                )
                completeLegacyMigrationIfNeeded()
                lastProjectionFailureDescription = nil
                phase = .ready

                finishConnectionCycle(cycleID)
                startEventLoop(connected, controller: controller)
                return
            } catch is CancellationError {
                if let candidate {
                    await cleanUpFailedCandidate(
                        candidate,
                        controller: controller
                    )
                }
                return
            } catch {
                recordFailure(error)
                if let candidate {
                    await cleanUpFailedCandidate(
                        candidate,
                        controller: controller
                    )
                }
                if await projectionDriver?.phase == .superseded {
                    phase = .unavailable
                    return
                }
                guard attempt < maximumConnectionAttempts,
                      backendOnlyHostShouldRetryConnection(after: error)
                else {
                    phase = .unavailable
                    return
                }
            }
        }
    }

    private func prepareDriver(
        rpc: any BackendOnlyProjectionDriverRPC,
        connection: BackendOnlyHostConnection,
        snapshot: TopologySnapshot,
        connectionGeneration: UInt64
    ) async throws -> BackendOnlyProjectionDriver {
        if let driver = projectionDriver {
            guard await driver.stableClientID == connection.stableClientID,
                  await driver.processInstanceID == connection.processInstanceID
            else {
                throw BackendOnlyProjectionDriverError.invalidIdentity
            }
            _ = try await driver.reconcileAfterReconnect(
                rpc: rpc,
                topology: snapshot,
                connectionGeneration: connectionGeneration,
                legacySelectedWorkspaceID: legacyMigrationPending
                    ? legacySelectedWorkspaceSeed : nil
            )
            return driver
        }

        let driver = try BackendOnlyProjectionDriver(
            rpc: rpc,
            logicalPresentationID: logicalPresentationID,
            stableClientID: connection.stableClientID,
            processInstanceID: connection.processInstanceID,
            connectionGeneration: connectionGeneration
        )
        projectionDriver = driver
        _ = try await driver.hydrate(
            topology: snapshot,
            legacySelectedWorkspaceID: legacyMigrationPending
                ? legacySelectedWorkspaceSeed : nil
        )
        return driver
    }

    private func allocateConnectionGeneration() throws -> UInt64 {
        guard nextConnectionGeneration != UInt64.max else {
            throw BackendOnlyProjectionDriverError.generationExhausted
        }
        let generation = nextConnectionGeneration
        nextConnectionGeneration += 1
        return generation
    }

    private func finishConnectionCycle(_ cycleID: UUID) {
        guard connectionCycleID == cycleID else { return }
        connectionCycleID = nil
        connectTask = nil
    }

    private func startEventLoop(
        _ connection: BackendOnlyHostConnection,
        controller: any BackendOnlyHostSessionControlling
    ) {
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            let events = await controller.events(for: connection)
            for await event in events {
                guard let self, self.isCurrent(connection) else { return }
                switch event {
                case .snapshot, .delta:
                    guard let snapshot = await controller.currentSnapshot(
                        for: connection
                    ), self.isCurrent(connection) else {
                        await self.connectionDidEnd(
                            connection,
                            controller: controller
                        )
                        return
                    }
                    self.enqueueTopology(snapshot)
                case .disconnected:
                    await self.connectionDidEnd(
                        connection,
                        controller: controller
                    )
                    return
                case .terminalActivitySnapshot, .terminalActivity,
                     .terminalActivityReceipt:
                    continue
                }
            }
            guard !Task.isCancelled else { return }
            await self?.connectionDidEnd(connection, controller: controller)
        }
    }

    private func enqueueTopology(_ snapshot: TopologySnapshot) {
        guard connection != nil else { return }
        if let pending = pendingTopologySnapshot,
           pending.authority == snapshot.authority,
           pending.revision > snapshot.revision
        {
            return
        }
        if let published = publishedProjection?.authority,
           published.authority == snapshot.authority,
           published.topologyRevision > snapshot.revision
        {
            return
        }
        pendingTopologySnapshot = snapshot
        maximumPendingProjectionRefreshCountObserved = max(
            maximumPendingProjectionRefreshCountObserved,
            1
        )
        startProjectionLaneIfNeeded()
    }

    private func enqueueProjectionIntents(
        _ intents: [BackendOnlyProjectionAbsoluteIntent]
    ) {
        guard !intents.isEmpty, connection != nil, projectionDriver != nil else {
            return
        }
        guard nextIntentSequence != UInt64.max else {
            recordFailure(BackendOnlyProjectionDriverError.intentSequenceExhausted)
            return
        }
        let sequence = nextIntentSequence
        var candidate = pendingIntents
        for (order, intent) in intents.enumerated() {
            candidate[backendOnlyHostProjectionIntentKey(for: intent)] = BackendOnlyHostPendingIntent(
                intent: intent,
                sequence: sequence,
                withinActionOrder: order
            )
        }
        guard candidate.count <= Self.maximumPendingIntentCount else {
            recordFailure(
                BackendOnlyProjectionDriverError.pendingIntentLimitExceeded(
                    maximum: Self.maximumPendingIntentCount
                )
            )
            return
        }
        nextIntentSequence += 1
        pendingIntents = candidate
        startProjectionLaneIfNeeded()
    }

    private func requestRepublish() {
        pendingRepublish = true
        startProjectionLaneIfNeeded()
    }

    private func startProjectionLaneIfNeeded() {
        guard projectionLaneTask == nil,
              let connection,
              let driver = projectionDriver,
              hasPendingProjectionWork
        else { return }
        let laneID = UUID()
        projectionLaneID = laneID
        projectionLaneTask = Task { @MainActor [weak self] in
            await self?.runProjectionLane(
                laneID: laneID,
                connection: connection,
                driver: driver
            )
        }
    }

    private var hasPendingProjectionWork: Bool {
        pendingTopologySnapshot != nil
            || pendingRepublish
            || !pendingIntents.isEmpty
    }

    private func runProjectionLane(
        laneID: UUID,
        connection: BackendOnlyHostConnection,
        driver: BackendOnlyProjectionDriver
    ) async {
        defer { finishProjectionLane(laneID) }

        while !Task.isCancelled, isCurrent(connection) {
            let topology = pendingTopologySnapshot
            pendingTopologySnapshot = nil
            let republish = pendingRepublish
            pendingRepublish = false
            let intents = pendingIntents.values.sorted {
                if $0.sequence != $1.sequence {
                    return $0.sequence < $1.sequence
                }
                return $0.withinActionOrder < $1.withinActionOrder
            }.map(\.intent)
            pendingIntents.removeAll(keepingCapacity: true)
            guard topology != nil || republish || !intents.isEmpty else { return }

            do {
                if let topology {
                    await driver.waitUntilIdle()
                    guard isCurrent(connection) else { return }
                    _ = try await driver.refreshTopology(topology)
                }
                if !intents.isEmpty {
                    _ = try await driver.submit(intents)
                }
                await driver.waitUntilIdle()
                guard isCurrent(connection) else { return }

                switch await driver.phase {
                case .ready:
                    guard let publication = await driver.publication else {
                        throw BackendOnlyProjectionDriverError
                            .protocolFenceMismatch
                    }
                    try await materializeAndPublish(
                        connection: connection,
                        driver: driver,
                        publication: publication
                    )
                    lastProjectionFailureDescription = nil
                    phase = .ready
                case .waitingForTopology:
                    return
                case .reconciliationRequired:
                    throw BackendOnlyProjectionDriverError.ambiguousTransport
                case .superseded:
                    throw BackendOnlyProjectionDriverError.superseded
                case .generationExhausted:
                    throw BackendOnlyProjectionDriverError.generationExhausted
                case .failed:
                    throw BackendOnlyProjectionDriverError.failed
                default:
                    throw BackendOnlyProjectionDriverError.notReady
                }
            } catch {
                recordFailure(error)
                let driverPhase = await driver.phase
                switch driverPhase {
                case .waitingForTopology:
                    if pendingTopologySnapshot != nil {
                        continue
                    }
                    return
                case .reconciliationRequired:
                    await connectionDidEnd(connection, controller: controller)
                case .superseded:
                    await terminateSupersededConnection(
                        connection,
                        controller: controller
                    )
                default:
                    await terminateFailedConnection(
                        connection,
                        controller: controller
                    )
                }
                return
            }
        }
    }

    private func finishProjectionLane(_ laneID: UUID) {
        guard projectionLaneID == laneID else { return }
        projectionLaneID = nil
        projectionLaneTask = nil
        if hasPendingProjectionWork {
            startProjectionLaneIfNeeded()
        }
    }

    private func materializeAndPublish(
        connection: BackendOnlyHostConnection,
        driver: BackendOnlyProjectionDriver,
        publication: BackendOnlyProjectionDriverPublication
    ) async throws {
        guard currentConnectionGeneration == publication.connectionGeneration,
              publication.logicalPresentationID == logicalPresentationID
        else {
            throw BackendOnlyProjectionDriverError.protocolFenceMismatch
        }

        let runtime: BackendOnlyProjectionRuntimeSnapshot?
        if publication.navigation.selectedWorkspaceID == nil,
           publication.topology.workspaces.isEmpty
        {
            runtime = nil
        } else {
            let plan = try projectionPlanner.plan(
                topology: publication.topology,
                navigation: BackendOnlyProjectionNavigationInput(
                    publication.navigation
                )
            )
            let fence = BackendOnlyProjectionRuntimeFence(
                connectionGeneration: publication.connectionGeneration,
                authority: publication.authority,
                topologyRevision: publication.topologyRevision,
                logicalPresentationID: publication.logicalPresentationID,
                projectionGeneration: publication.navigation.generation
            )
            _ = try await runtimeReconciler.apply(
                session: connection.session,
                fence: fence,
                plan: plan
            )
            runtime = runtimeReconciler.snapshot
            guard runtime?.fence == fence else {
                throw BackendOnlyProjectionRuntimeReconcilerError.staleFence
            }
        }

        guard isCurrent(connection),
              await driver.publication == publication
        else {
            requestRepublish()
            return
        }
        publishedProjection = BackendOnlyHostPublishedProjection(
            authority: publication,
            runtime: runtime
        )
    }

    private func connectionDidEnd(
        _ ended: BackendOnlyHostConnection,
        controller: (any BackendOnlyHostSessionControlling)?
    ) async {
        guard isCurrent(ended), let controller else { return }
        let driver = projectionDriver
        let runtimeFence = runtimeReconciler.snapshot?.fence

        connection = nil
        currentConnectionGeneration = nil
        clearProjectionLane()
        publishedProjection = nil
        phase = .connecting
        eventTask = nil

        if let runtimeFence {
            _ = await runtimeReconciler.disconnect(
                session: ended.session,
                fence: runtimeFence
            )
        }
        do {
            try await driver?.prepareForReconnect()
        } catch {
            recordFailure(error)
        }
        await controller.invalidate(ended)
        await driver?.waitUntilIdle()

        switch await driver?.phase {
        case .superseded, .generationExhausted:
            phase = .unavailable
        case .failed:
            projectionDriver = nil
            scheduleConnectionCycle()
        default:
            scheduleConnectionCycle()
        }
    }

    private func terminateSupersededConnection(
        _ ended: BackendOnlyHostConnection,
        controller: (any BackendOnlyHostSessionControlling)?
    ) async {
        guard isCurrent(ended), let controller else { return }
        let runtimeFence = runtimeReconciler.snapshot?.fence
        connection = nil
        currentConnectionGeneration = nil
        clearProjectionLane()
        publishedProjection = nil
        phase = .unavailable
        eventTask?.cancel()
        eventTask = nil
        if let runtimeFence {
            _ = await runtimeReconciler.disconnect(
                session: ended.session,
                fence: runtimeFence
            )
        }
        await controller.invalidate(ended)
    }

    private func terminateFailedConnection(
        _ ended: BackendOnlyHostConnection,
        controller: (any BackendOnlyHostSessionControlling)?
    ) async {
        await terminateSupersededConnection(ended, controller: controller)
    }

    private func cleanUpFailedCandidate(
        _ candidate: BackendOnlyHostConnection,
        controller: any BackendOnlyHostSessionControlling
    ) async {
        let wasCurrent = isCurrent(candidate)
        let runtimeFence = wasCurrent ? runtimeReconciler.snapshot?.fence : nil
        if wasCurrent {
            connection = nil
            currentConnectionGeneration = nil
            publishedProjection = nil
            clearProjectionLane()
        }
        if let runtimeFence {
            _ = await runtimeReconciler.disconnect(
                session: candidate.session,
                fence: runtimeFence
            )
        }
        if let projectionDriver {
            do {
                try await projectionDriver.prepareForReconnect()
            } catch {
                if await projectionDriver.phase == .failed {
                    self.projectionDriver = nil
                }
            }
        }
        await controller.invalidate(candidate)
        await projectionDriver?.waitUntilIdle()
    }

    private func clearProjectionLane() {
        projectionLaneTask?.cancel()
        projectionLaneTask = nil
        projectionLaneID = nil
        pendingTopologySnapshot = nil
        pendingRepublish = false
        pendingIntents.removeAll(keepingCapacity: true)
    }

    private func completeLegacyMigrationIfNeeded() {
        guard legacyMigrationPending else { return }
        defaults.removeObject(forKey: Self.selectedWorkspaceDefaultsKey)
        legacyMigrationPending = false
    }

    private func isCurrent(_ candidate: BackendOnlyHostConnection) -> Bool {
        connection?.session === candidate.session
    }

    private func recordFailure(_ error: any Error) {
        lastProjectionFailureDescription = String(reflecting: error)
    }
}

private func backendOnlyHostShouldRetryConnection(after error: any Error) -> Bool {
    guard let connectionError = error as? BackendOnlyHostConnectionError else {
        return true
    }
    return connectionError == .backendUnavailable
}

private func backendOnlyHostProjectionIntentKey(
    for intent: BackendOnlyProjectionAbsoluteIntent
) -> BackendOnlyHostProjectionIntentKey {
    switch intent {
    case let .workspaceAssignment(workspaceID, _):
        .workspaceBinding(workspaceID)
    case .selectWorkspace:
        .selectedWorkspace
    case let .selectScreen(workspaceID, _):
        .selectedScreen(workspaceID)
    case let .activatePane(workspaceID, screenID, _):
        .activePane(workspaceID, screenID)
    case let .setZoomedPane(workspaceID, screenID, _):
        .zoomedPane(workspaceID, screenID)
    case let .selectSurface(workspaceID, screenID, paneID, _):
        .selectedSurface(workspaceID, screenID, paneID)
    }
}
