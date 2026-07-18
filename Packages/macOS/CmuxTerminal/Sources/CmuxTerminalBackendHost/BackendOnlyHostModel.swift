public import CmuxTerminalBackend
public import Foundation
public import SwiftUI

@MainActor
public final class BackendOnlyHostModel: ObservableObject {
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
    private var connection: BackendOnlyHostConnection?
    private var eventTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var connectionCycleID: UUID?
    private var projectionUpdateTask: Task<BackendProjectionState?, Never>?
    private var projection: BackendProjectionState?

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
        maximumConnectionAttempts: Int
    ) {
        precondition(maximumConnectionAttempts > 0)
        self.controller = controller
        self.defaults = defaults
        self.maximumConnectionAttempts = maximumConnectionAttempts
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
        retireActiveRuntime()
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
        materializeSelectedRuntime()
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
        projection = nil
        projectionUpdateTask?.cancel()
        projectionUpdateTask = nil
        topology = nil
        retireActiveRuntime()
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
            materializeSelectedRuntime()
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
            materializeSelectedRuntime()
            persistProjectionSelection()
        } else {
            selectWorkspace(selected)
        }
    }

    private func materializeSelectedRuntime() {
        let desiredSelection = selectedWorkspaceID.flatMap { selectedWorkspaceID in
            workspaces.first(
                where: { $0.uuid.rawValue == selectedWorkspaceID }
            )?.backendOnlyFirstTerminal
        }
        if let activeRuntime, activeRuntime.selection != desiredSelection {
            retireActiveRuntime()
        }
        guard activeRuntime == nil,
              let connection,
              let selection = desiredSelection else { return }
        activeRuntime = BackendOnlyTerminalRuntime(
            session: connection.session,
            selection: selection
        )
    }

    private func retireActiveRuntime() {
        guard let retiredRuntime = activeRuntime else { return }
        activeRuntime = nil
        Task { await retiredRuntime.shutdown() }
    }

    private func persistProjectionSelection() {
        guard let connection,
              let projection,
              let claimID = projection.claimID,
              let selectedWorkspaceID,
              let workspace = workspaces.first(
                where: { $0.uuid.rawValue == selectedWorkspaceID }
              ),
              let screen = workspace.screens.first
        else { return }

        let prior = projectionUpdateTask
        let currentProjection = projection
        let logicalPresentationID = logicalPresentationID
        projectionUpdateTask = Task { @MainActor [weak self] in
            let current = await prior?.value ?? currentProjection
            guard current.claimID == claimID else { return nil }
            do {
                let updated = try await connection.session.updateProjectionState(
                    logicalPresentationID: logicalPresentationID,
                    claimID: claimID,
                    expectedGeneration: current.generation,
                    workspaces: [
                        BackendProjectionWorkspaceState(
                            workspaceID: workspace.uuid,
                            selectedScreenID: screen.uuid
                        ),
                    ]
                )
                guard self?.connection?.session === connection.session else {
                    return nil
                }
                self?.projection = updated
                return updated
            } catch {
                return nil
            }
        }
    }
}
