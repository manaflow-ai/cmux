import CmuxFleet
import Foundation

// Test-only mutable clock; suites using it are serialized and mutate it from MainActor tests.
final class FleetEngineDateBox: @unchecked Sendable {
    var now: Date

    init(_ now: Date = Date(timeIntervalSince1970: 10_000)) {
        self.now = now
    }

    func advance(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

@MainActor
final class FakeFleetActuator: FleetActuating {
    struct ProvisionCall: Equatable {
        var taskID: FleetTaskID
        var fleetID: FleetID
    }

    var provisionCalls: [ProvisionCall] = []
    var provisionResults: [FleetTaskID: Result<FleetProvisionOutcome, FleetActuationError>] = [:]
    var suspendedProvisionTaskIDs: Set<FleetTaskID> = []
    var provisionContinuations: [FleetTaskID: CheckedContinuation<Result<FleetProvisionOutcome, FleetActuationError>, Never>] = [:]
    var sendAgentCommandTexts: [String] = []
    var sendAgentCommandSucceeds = true
    var kills: [(workspaceID: String, surfaceID: String, pid: Int32?)] = []
    var closes: [String] = []
    var notifications: [(fleetID: FleetID, taskID: FleetTaskID, kind: FleetNotificationKind)] = []

    func provisionWorkspace(task: FleetTask, fleet: FleetConfig) async -> Result<FleetProvisionOutcome, FleetActuationError> {
        provisionCalls.append(ProvisionCall(taskID: task.id, fleetID: fleet.id))
        if suspendedProvisionTaskIDs.contains(task.id) {
            return await withCheckedContinuation { continuation in
                provisionContinuations[task.id] = continuation
            }
        }
        if let result = provisionResults[task.id] {
            return result
        }
        return .success(FleetProvisionOutcome(
            workspaceID: "workspace-\(task.id.rawValue)",
            surfaceID: "surface-\(task.id.rawValue)",
            directoryPath: "\(fleet.workspaceRoot)/task",
            branch: "fleet/task",
            isBrandNew: true
        ))
    }

    func sendAgentCommand(workspaceID: String, surfaceID: String, text: String) -> Bool {
        sendAgentCommandTexts.append(text)
        return sendAgentCommandSucceeds
    }

    func killAgent(workspaceID: String, surfaceID: String, pid: Int32?) {
        kills.append((workspaceID, surfaceID, pid))
    }

    func closeWorkspace(workspaceID: String) {
        closes.append(workspaceID)
    }

    func postNotification(fleet: FleetConfig, task: FleetTask, kind: FleetNotificationKind) {
        notifications.append((fleet.id, task.id, kind))
    }

    func suspendProvision(for taskID: FleetTaskID) {
        suspendedProvisionTaskIDs.insert(taskID)
    }

    func completeProvision(taskID: FleetTaskID, result: Result<FleetProvisionOutcome, FleetActuationError>) {
        suspendedProvisionTaskIDs.remove(taskID)
        provisionContinuations.removeValue(forKey: taskID)?.resume(returning: result)
    }
}

@MainActor
final class FakeFleetWorld: FleetWorldReading {
    var existingWorkspaces: Set<String> = []
    var pullRequests: [String: FleetPullRequestStatus] = [:]
    var promptIdle: [String: Bool] = [:]

    func workspaceExists(workspaceID: String) -> Bool {
        existingWorkspaces.contains(workspaceID)
    }

    func pullRequestStatus(workspaceID: String, directoryPath: String?, branch: String?) -> FleetPullRequestStatus? {
        pullRequests[workspaceID]
    }

    func isShellPromptIdle(workspaceID: String, surfaceID: String) -> Bool? {
        promptIdle["\(workspaceID)|\(surfaceID)"]
    }
}

@MainActor
final class FakeFleetTimers: FleetTimerScheduling {
    struct Scheduled: Equatable {
        var key: String
        var delayMS: Int
    }

    var scheduled: [Scheduled] = []
    var cancelled: [String] = []
    private var handlers: [String: @MainActor () -> Void] = [:]

    func schedule(key: String, delayMS: Int, onFire: @escaping @MainActor () -> Void) {
        scheduled.append(Scheduled(key: key, delayMS: delayMS))
        handlers[key] = onFire
    }

    func cancel(key: String) {
        cancelled.append(key)
        handlers.removeValue(forKey: key)
    }

    func cancelAll() {
        cancelled.append(contentsOf: handlers.keys.sorted())
        handlers.removeAll()
    }

    func fire(_ key: String) {
        handlers[key]?()
    }

    func hasScheduled(prefix: String) -> Bool {
        scheduled.contains { $0.key.hasPrefix(prefix) }
    }
}

@MainActor
final class FakeFleetProcessWatcher: FleetProcessWatching {
    var watched: [Int32] = []
    var cancelled: [Int32] = []
    private var handlers: [Int32: @MainActor () -> Void] = [:]

    func watchExit(pid: Int32, onExit: @escaping @MainActor () -> Void) {
        watched.append(pid)
        handlers[pid] = onExit
    }

    func cancel(pid: Int32) {
        cancelled.append(pid)
        handlers.removeValue(forKey: pid)
    }

    func fire(pid: Int32) {
        handlers[pid]?()
    }
}

@MainActor
final class FakeFleetPersistence: FleetPersisting {
    var loadState: FleetPersistedState?
    var saved: [FleetPersistedState] = []

    func save(_ state: FleetPersistedState) {
        saved.append(state)
    }

    func load() -> FleetPersistedState? {
        loadState
    }
}

@MainActor
struct FleetEngineHarness {
    var dateBox = FleetEngineDateBox()
    var actuator = FakeFleetActuator()
    var world = FakeFleetWorld()
    var timers = FakeFleetTimers()
    var processWatcher = FakeFleetProcessWatcher()
    var persistence = FakeFleetPersistence()

    func engine(reconcileIntervalMS: Int = 30_000, promptIdleGraceMS: Int = 120_000) -> FleetEngine {
        FleetEngine(dependencies: FleetEngineDependencies(
            actuator: actuator,
            world: world,
            timers: timers,
            processWatcher: processWatcher,
            persistence: persistence,
            now: { dateBox.now },
            reconcileIntervalMS: reconcileIntervalMS,
            promptIdleGraceMS: promptIdleGraceMS
        ))
    }
}
