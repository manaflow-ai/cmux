import CmuxTerminalCore
import Foundation

/// App composition adapter from terminal dirty signals to Workspace lifecycle state.
@MainActor
final class AgentTerminalStateRuntime {
    private let scheduler: AgentTerminalStateDetectionScheduler
    private let classificationWorker = AgentTerminalClassificationWorker()
    private var observers: [UUID: AgentTerminalStateSurfaceObserver] = [:]
    private var registrationTasks: [UUID: Task<Void, Never>] = [:]
    private var teardownTasks: [UUID: Task<Void, Never>] = [:]
    private var teardownTokens: [UUID: UUID] = [:]
    private var updateTask: Task<Void, Never>?

    init() {
        scheduler = AgentTerminalStateDetectionScheduler(clock: .continuous())
    }

    deinit {
        updateTask?.cancel()
        registrationTasks.values.forEach { $0.cancel() }
        teardownTasks.values.forEach { $0.cancel() }
    }

    func install(workspaceID: UUID, surfaceID: UUID, signal: AgentTerminalDirtySignal) {
        startUpdateConsumerIfNeeded()
        let observer = AgentTerminalStateSurfaceObserver(workspaceID: workspaceID, surfaceID: surfaceID)
        observers[surfaceID] = observer
        let worker = classificationWorker
        registrationTasks[surfaceID] = Task {
            await scheduler.start(surfaceID: surfaceID, signal: signal) { revision in
                guard signal.currentRevision() == revision,
                      let snapshot = await observer.capture() else { return nil }
                guard signal.currentRevision() == revision else { return nil }
                return await worker.classify(surfaceID: surfaceID, snapshot: snapshot)
            }
        }
        // Runtime installation itself is new evidence even before the first PTY chunk.
        signal.markDirty()
    }

    func drop(surfaceID: UUID) {
        let observer = observers.removeValue(forKey: surfaceID)
        let registrationTask = registrationTasks.removeValue(forKey: surfaceID)
        registrationTask?.cancel()
        let teardownToken = UUID()
        teardownTokens[surfaceID] = teardownToken
        let scheduler = scheduler
        let classificationWorker = classificationWorker
        teardownTasks[surfaceID] = Task { [weak self] in
            _ = await registrationTask?.value
            await scheduler.stop(surfaceID: surfaceID)
            await classificationWorker.remove(surfaceID: surfaceID)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard self?.teardownTokens[surfaceID] == teardownToken else { return }
                self?.teardownTasks.removeValue(forKey: surfaceID)
                self?.teardownTokens.removeValue(forKey: surfaceID)
            }
        }
        guard let observer, let workspace = AppDelegate.shared?.workspaceFor(tabId: observer.workspaceID) else { return }
        workspace.clearDetectedAgentLifecycle(panelId: surfaceID)
    }

    private func startUpdateConsumerIfNeeded() {
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let scheduler = self?.scheduler else { return }
            let updates = await scheduler.updates()
            for await update in updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.apply(update)
            }
        }
    }

    private func apply(_ update: AgentTerminalDetectionUpdate) {
        guard let observer = observers[update.surfaceID],
              let workspace = AppDelegate.shared?.workspaceFor(tabId: observer.workspaceID) else { return }
        workspace.setDetectedAgentLifecycle(
            statusKey: update.classification.statusKey,
            familyID: update.classification.familyID,
            panelId: update.surfaceID,
            state: update.classification.state
        )
        observer.recordPublished(update.classification)
    }
}
