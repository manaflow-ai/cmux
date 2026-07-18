public import CmuxTerminalBackend
public import Foundation
public import SwiftUI

@MainActor
protocol BackendOnlyHostRuntimeLifecycle: AnyObject {
    var selection: BackendOnlyTerminalSelection { get }
    func shutdown() async
}

extension BackendOnlyTerminalRuntime: BackendOnlyHostRuntimeLifecycle {}

typealias BackendOnlyHostRuntimeFactory = @MainActor (
    BackendCanonicalSession,
    BackendOnlyTerminalSelection
) -> any BackendOnlyHostRuntimeLifecycle

@MainActor
public final class BackendOnlyHostModel: ObservableObject {
    private struct PendingProjectionWrite: Sendable {
        let connection: BackendOnlyHostConnection
        let claimID: UUID
        let workspace: BackendProjectionWorkspaceState
    }

    private struct ProjectionWriteAttempt: Sendable {
        let pending: PendingProjectionWrite
        let expectedGeneration: UInt64
    }

    private struct ManagedRuntime {
        let session: BackendCanonicalSession
        let lifecycle: any BackendOnlyHostRuntimeLifecycle
    }

    private struct RuntimeTarget {
        let session: BackendCanonicalSession
        let selection: BackendOnlyTerminalSelection
    }

    public enum Phase: Equatable {
        case connecting
        case ready
        case unavailable
    }

    @Published public private(set) var phase: Phase = .connecting
    @Published public private(set) var topology: CanonicalTopology?
    @Published public private(set) var selectedWorkspaceID: UUID?
    @Published public private(set) var activeRuntime: BackendOnlyTerminalRuntime?

    private static let logicalPresentationDefaultsKey =
        "backendOnly.logicalPresentationID"
    private static let selectedWorkspaceDefaultsKey =
        "backendOnly.selectedWorkspaceID"
    private static let defaultMaximumConnectionAttempts = 3

    private let controller: (any BackendOnlyHostSessionControlling)?
    private let defaults: UserDefaults
    private let logicalPresentationID: UUID
    private let maximumConnectionAttempts: Int
    private let runtimeFactory: BackendOnlyHostRuntimeFactory
    private var connection: BackendOnlyHostConnection?
    private var eventTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var connectionCycleID: UUID?
    // One writer owns the admitted RPC. Rapid selections overwrite one pending
    // value, bounding persistence work at one in-flight plus one queued write.
    private var projectionUpdateTask: Task<Void, Never>?
    private var projectionWriterID: UUID?
    private var pendingProjectionWrite: PendingProjectionWrite?
    private var projection: BackendProjectionState?
    private var managedRuntime: ManagedRuntime?
    // Selection, topology, and connection changes only update desired state.
    // This single task serializes retirement before replacement materialization.
    private var runtimeReconciliationTask: Task<Void, Never>?

    public convenience init(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard
    ) {
        self.init(
            controller: BackendOnlySessionController(
                bundleURL: bundleURL,
                bundleIdentifier: bundleIdentifier
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
        self.runtimeFactory = runtimeFactory ?? { session, selection in
            BackendOnlyTerminalRuntime(
                session: session,
                selection: selection
            )
        }
        if let logicalPresentationID {
            self.logicalPresentationID = logicalPresentationID
        } else if let stored = defaults.string(forKey: Self.logicalPresentationDefaultsKey),
           let value = UUID(uuidString: stored) {
            self.logicalPresentationID = value
        } else {
            let value = UUID()
            self.logicalPresentationID = value
            defaults.set(
                value.uuidString.lowercased(),
                forKey: Self.logicalPresentationDefaultsKey
            )
        }
        if let stored = defaults.string(forKey: Self.selectedWorkspaceDefaultsKey) {
            selectedWorkspaceID = UUID(uuidString: stored)
        }
    }

    deinit {
        eventTask?.cancel()
        connectTask?.cancel()
        runtimeReconciliationTask?.cancel()
        // A selection already admitted to the daemon projection journal must
        // survive SwiftUI model teardown. The task owns only value snapshots
        // and a weak model reference, so allow its final write to complete.
    }

    public var workspaces: [CanonicalWorkspace] {
        topology?.workspaces ?? []
    }

    public func start() {
        scheduleConnectionCycle()
    }

    func awaitCurrentConnectionCycle() async {
        let task = connectTask
        await task?.value
    }

    func awaitProjectionPersistence() async {
        let task = projectionUpdateTask
        await task?.value
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
            await self?.runConnectionCycle(controller: controller, cycleID: cycleID)
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
                let connection = try await controller.connect()
                candidate = connection
                let projection = try await controller.claimProjectionState(
                    for: connection,
                    logicalPresentationID: logicalPresentationID
                )
                guard let snapshot = await controller.currentSnapshot(for: connection) else {
                    throw BackendCanonicalSessionError.notConnected
                }
                try Task.checkCancellation()
                guard connectionCycleID == cycleID, self.connection == nil else {
                    await controller.invalidate(connection)
                    return
                }

                self.connection = connection
                self.projection = projection
                install(snapshot)
                selectInitialWorkspace()
                phase = .ready

                // Clear the cycle before subscribing. A session that is already
                // disconnected can then schedule its replacement immediately.
                finishConnectionCycle(cycleID)
                startEventLoop(connection, controller: controller)
                return
            } catch is CancellationError {
                if let candidate {
                    await controller.invalidate(candidate)
                }
                return
            } catch {
                if let candidate {
                    await controller.invalidate(candidate)
                }
                guard attempt < maximumConnectionAttempts,
                      Self.shouldRetryConnection(after: error) else {
                    phase = .unavailable
                    return
                }
                // Each next attempt is driven by completion of the preceding
                // readiness/claim event. The readiness probe owns its bounded
                // launchd backoff, so the host never polls or sleeps for state.
            }
        }
    }

    private func finishConnectionCycle(_ cycleID: UUID) {
        guard connectionCycleID == cycleID else { return }
        connectionCycleID = nil
        connectTask = nil
    }

    private static func shouldRetryConnection(after error: any Error) -> Bool {
        guard let connectionError = error as? BackendOnlyHostConnectionError else {
            return true
        }
        return connectionError == .backendUnavailable
    }

    public func selectWorkspace(_ identifier: UUID?) {
        guard selectedWorkspaceID != identifier else { return }
        selectedWorkspaceID = identifier
        if let identifier {
            defaults.set(
                identifier.uuidString.lowercased(),
                forKey: Self.selectedWorkspaceDefaultsKey
            )
        } else {
            defaults.removeObject(
                forKey: Self.selectedWorkspaceDefaultsKey
            )
        }
        scheduleRuntimeReconciliation()
        persistProjectionSelection()
    }

    public func createWorkspace() {
        guard let connection else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let snapshot = await connection.session.currentSnapshot(),
                  self.isCurrent(connection)
            else { return }
            do {
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
                guard self.isCurrent(connection) else { return }
                guard let updated = await connection.session.currentSnapshot(),
                      self.isCurrent(connection) else { return }
                self.install(updated)
                self.selectWorkspace(workspaceID.rawValue)
            } catch {
                if self.isCurrent(connection) {
                    self.phase = .unavailable
                }
            }
        }
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
                    if let snapshot = await controller.currentSnapshot(for: connection),
                       self.isCurrent(connection) {
                        self.install(snapshot)
                    }
                case .disconnected:
                    await self.connectionDidEnd(connection, controller: controller)
                    return
                case .terminalActivitySnapshot, .terminalActivity,
                     .terminalActivityReceipt, .rendererWorkerChanged,
                     .rendererPresentationReady:
                    continue
                }
            }
            guard !Task.isCancelled else { return }
            await self?.connectionDidEnd(connection, controller: controller)
        }
    }

    private func connectionDidEnd(
        _ ended: BackendOnlyHostConnection,
        controller: any BackendOnlyHostSessionControlling
    ) async {
        guard isCurrent(ended) else { return }

        connection = nil
        cancelProjectionPersistence()
        projection = nil
        topology = nil
        scheduleRuntimeReconciliation()
        phase = .connecting
        eventTask = nil

        await controller.invalidate(ended)
        scheduleConnectionCycle()
    }

    private func isCurrent(_ candidate: BackendOnlyHostConnection) -> Bool {
        connection?.session === candidate.session
    }

    private func install(_ snapshot: TopologySnapshot) {
        topology = snapshot.topology
        if let selectedWorkspaceID,
           !snapshot.topology.workspaces.contains(
            where: { $0.uuid.rawValue == selectedWorkspaceID }
           ) {
            selectWorkspace(snapshot.topology.workspaces.first?.uuid.rawValue)
        } else {
            scheduleRuntimeReconciliation()
        }
    }

    private func selectInitialWorkspace() {
        let valid = Set(workspaces.map { $0.uuid.rawValue })
        let projected = projection?.workspaces.first?.workspaceID.rawValue
        let selected = [selectedWorkspaceID, projected]
            .compactMap { $0 }
            .first(where: valid.contains)
            ?? workspaces.first?.uuid.rawValue
        if selectedWorkspaceID == selected {
            scheduleRuntimeReconciliation()
            persistProjectionSelection()
        } else {
            selectWorkspace(selected)
        }
    }

    private func desiredRuntimeTarget() -> RuntimeTarget? {
        guard let connection,
              let selectedWorkspaceID,
              let selection = workspaces.first(
                where: { $0.uuid.rawValue == selectedWorkspaceID }
              )?.backendOnlyFirstTerminal
        else { return nil }
        return RuntimeTarget(
            session: connection.session,
            selection: selection
        )
    }

    private func scheduleRuntimeReconciliation() {
        let desired = desiredRuntimeTarget()
        if let managedRuntime,
           let desired,
           runtime(managedRuntime, matches: desired) {
            publish(managedRuntime)
        } else {
            publish(nil)
        }

        guard runtimeReconciliationTask == nil,
              !runtimeIsReconciled(with: desired) else { return }
        runtimeReconciliationTask = Task { @MainActor [weak self] in
            await self?.reconcileRuntime()
        }
    }

    private func reconcileRuntime() async {
        defer { runtimeReconciliationTask = nil }

        while !Task.isCancelled {
            let desired = desiredRuntimeTarget()
            if let current = managedRuntime {
                if let desired, runtime(current, matches: desired) {
                    publish(current)
                    return
                }
                publish(nil)
                managedRuntime = nil
                await current.lifecycle.shutdown()
                // Every suspension invalidates the prior desired snapshot. The
                // next loop derives the newest selection and connection again.
                continue
            }

            guard let desired else {
                publish(nil)
                return
            }
            let lifecycle = runtimeFactory(
                desired.session,
                desired.selection
            )
            let replacement = ManagedRuntime(
                session: desired.session,
                lifecycle: lifecycle
            )
            managedRuntime = replacement
            publish(replacement)
            return
        }
    }

    private func runtimeIsReconciled(with desired: RuntimeTarget?) -> Bool {
        switch (managedRuntime, desired) {
        case (nil, nil):
            true
        case let (current?, desired?):
            runtime(current, matches: desired)
        default:
            false
        }
    }

    private func runtime(
        _ current: ManagedRuntime,
        matches desired: RuntimeTarget
    ) -> Bool {
        current.session === desired.session
            && current.lifecycle.selection == desired.selection
    }

    private func publish(_ runtime: ManagedRuntime?) {
        let terminalRuntime = runtime?.lifecycle as? BackendOnlyTerminalRuntime
        guard activeRuntime !== terminalRuntime else { return }
        activeRuntime = terminalRuntime
    }

    private func persistProjectionSelection() {
        guard let controller,
              let connection,
              let projection,
              let claimID = projection.claimID,
              projection.logicalPresentationID == logicalPresentationID,
              let selectedWorkspaceID,
              let workspace = workspaces.first(
                where: { $0.uuid.rawValue == selectedWorkspaceID }
              ),
              let screen = workspace.screens.first
        else {
            pendingProjectionWrite = nil
            return
        }

        pendingProjectionWrite = PendingProjectionWrite(
            connection: connection,
            claimID: claimID,
            workspace: BackendProjectionWorkspaceState(
                workspaceID: workspace.uuid,
                selectedScreenID: screen.uuid
            )
        )
        startProjectionWriterIfNeeded(controller: controller)
    }

    private func startProjectionWriterIfNeeded(
        controller: any BackendOnlyHostSessionControlling
    ) {
        guard projectionUpdateTask == nil, pendingProjectionWrite != nil else { return }
        let writerID = UUID()
        projectionWriterID = writerID
        let logicalPresentationID = logicalPresentationID
        projectionUpdateTask = Task { @MainActor [weak self, controller] in
            while !Task.isCancelled,
                  let attempt = self?.takeNextProjectionWrite(writerID: writerID) {
                let updated: BackendProjectionState?
                do {
                    updated = try await controller.updateProjectionState(
                        for: attempt.pending.connection,
                        logicalPresentationID: logicalPresentationID,
                        claimID: attempt.pending.claimID,
                        expectedGeneration: attempt.expectedGeneration,
                        workspaces: [attempt.pending.workspace]
                    )
                } catch {
                    updated = nil
                }

                guard !Task.isCancelled, let self else { return }
                guard self.projectionWriterID == writerID else { return }
                guard self.connection?.session === attempt.pending.connection.session,
                      self.projection?.claimID == attempt.pending.claimID
                else {
                    self.pendingProjectionWrite = nil
                    break
                }
                if let updated,
                   updated.logicalPresentationID == logicalPresentationID,
                   updated.claimID == attempt.pending.claimID,
                   updated.generation > attempt.expectedGeneration {
                    self.projection = updated
                }
                // A failed attempt is never retried on its own. The loop runs
                // again only when a selection made during the RPC replaced the
                // single pending slot with a newer desired workspace.
            }
            self?.finishProjectionWriter(writerID: writerID)
        }
    }

    private func takeNextProjectionWrite(
        writerID: UUID
    ) -> ProjectionWriteAttempt? {
        guard projectionWriterID == writerID,
              let pending = pendingProjectionWrite
        else { return nil }
        pendingProjectionWrite = nil
        guard connection?.session === pending.connection.session,
              let projection,
              projection.logicalPresentationID == logicalPresentationID,
              projection.claimID == pending.claimID
        else { return nil }
        return ProjectionWriteAttempt(
            pending: pending,
            expectedGeneration: projection.generation
        )
    }

    private func finishProjectionWriter(writerID: UUID) {
        guard projectionWriterID == writerID else { return }
        projectionWriterID = nil
        projectionUpdateTask = nil
    }

    private func cancelProjectionPersistence() {
        let task = projectionUpdateTask
        projectionWriterID = nil
        projectionUpdateTask = nil
        pendingProjectionWrite = nil
        task?.cancel()
    }
}
