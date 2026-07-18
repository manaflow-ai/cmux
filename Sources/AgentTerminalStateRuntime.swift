import CmuxFoundation
import CmuxTerminal
import CmuxTerminalCore
import Foundation
import os

/// Thread-safe, content-free projection of the detector's last published values.
/// Writers update it after classification; readers only copy cached metadata.
final class AgentTerminalObservationCache: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [UUID: CmuxAgentTerminalObservation]())

    func replace(surfaceID: UUID, with observation: CmuxAgentTerminalObservation?) {
        state.withLock { observations in
            observations[surfaceID] = observation
        }
    }

    func snapshot() -> [CmuxAgentTerminalObservation] {
        state.withLock { observations in
            observations.values.sorted {
                if $0.workspaceID != $1.workspaceID {
                    return $0.workspaceID.uuidString < $1.workspaceID.uuidString
                }
                return $0.surfaceID.uuidString < $1.surfaceID.uuidString
            }
        }
    }
}

/// App composition adapter from terminal dirty signals to Workspace lifecycle state.
@MainActor
final class AgentTerminalStateRuntime {
    private let scheduler: AgentTerminalStateDetectionScheduler
    nonisolated private let observationCache: AgentTerminalObservationCache
    private let classificationWorker = AgentTerminalClassificationWorker()
    private let surfaceTasks = AgentTerminalSurfaceTaskSequencer()
    private var observers: [UUID: AgentTerminalStateSurfaceObserver] = [:]

    nonisolated init(observationCache: AgentTerminalObservationCache) {
        self.observationCache = observationCache
        scheduler = AgentTerminalStateDetectionScheduler(clock: .continuous())
    }

    func install(
        workspaceID: UUID,
        surfaceID: UUID,
        expectedRuntimeGeneration: UInt64,
        signal: AgentTerminalDirtySignal
    ) {
        let observer = AgentTerminalStateSurfaceObserver(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            expectedRuntimeGeneration: expectedRuntimeGeneration
        )
        observers[surfaceID] = observer
        observationCache.replace(surfaceID: surfaceID, with: nil)
        let worker = classificationWorker
        surfaceTasks.install(surfaceID: surfaceID) { [weak self, scheduler] in
            await scheduler.start(surfaceID: surfaceID, signal: signal) { revision in
                guard signal.currentRevision() == revision,
                      let snapshot = await observer.capture() else { return nil }
                guard signal.currentRevision() == revision else { return nil }
                return await worker.classify(surfaceID: surfaceID, snapshot: snapshot)
            } deliver: { update in
                await self?.apply(
                    update,
                    expectedRuntimeGeneration: expectedRuntimeGeneration
                )
            }
        }
        // Runtime installation itself is new evidence even before the first PTY chunk.
        signal.markDirty()
    }

    func drop(surfaceID: UUID, surfaceGeneration: UInt64) {
        guard observers[surfaceID]?.expectedRuntimeGeneration == surfaceGeneration else { return }
        let observer = observers.removeValue(forKey: surfaceID)
        observationCache.replace(surfaceID: surfaceID, with: nil)
        let scheduler = scheduler
        let classificationWorker = classificationWorker
        surfaceTasks.drop(surfaceID: surfaceID) {
            await scheduler.stop(surfaceID: surfaceID)
            await classificationWorker.remove(surfaceID: surfaceID)
        }
        guard let observer, let workspace = AppDelegate.shared?.workspaceFor(tabId: observer.workspaceID) else { return }
        workspace.clearDetectedAgentLifecycle(panelId: surfaceID)
    }

    private func apply(
        _ update: AgentTerminalDetectionUpdate,
        expectedRuntimeGeneration: UInt64
    ) {
        guard let observer = observers[update.surfaceID],
              observer.expectedRuntimeGeneration == expectedRuntimeGeneration,
              update.classification.processIdentity.runtimeGeneration == expectedRuntimeGeneration,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: observer.workspaceID) else { return }
        workspace.setDetectedAgentLifecycle(
            statusKey: update.classification.statusKey,
            familyID: update.classification.familyID,
            panelId: update.surfaceID,
            state: update.classification.state
        )
        updateObservation(update, observer: observer)
        observer.recordPublished(update.classification)
    }

    private func updateObservation(
        _ update: AgentTerminalDetectionUpdate,
        observer: AgentTerminalStateSurfaceObserver
    ) {
        let classification = update.classification
        guard let familyID = classification.familyID,
              let sessionProviderID = classification.sessionProviderID,
              let state = classification.state.observedState else {
            observationCache.replace(surfaceID: update.surfaceID, with: nil)
            return
        }
        let process = classification.processIdentity
        let cwd = Workspace.processCurrentWorkingDirectory(pid: process.pid)
            ?? GhosttyApp.terminalSurfaceRegistry
                .terminalSurface(id: update.surfaceID)?
                .requestedWorkingDirectory
        observationCache.replace(
            surfaceID: update.surfaceID,
            with: CmuxAgentTerminalObservation(
                runtimeID: TerminalSurface.managedCmuxRuntimeId,
                workspaceID: observer.workspaceID,
                surfaceID: update.surfaceID,
                surfaceGeneration: observer.expectedRuntimeGeneration,
                revision: update.revision,
                familyID: familyID,
                sessionProviderID: sessionProviderID,
                lifecycleAuthoritative: classification.lifecycleAuthoritative,
                state: state,
                pid: process.pid,
                processStartSeconds: process.startSeconds,
                processStartMicroseconds: process.startMicroseconds,
                cwd: cwd,
                publishedAt: Date().timeIntervalSince1970
            )
        )
    }
}

private extension AgentTerminalSemanticState {
    var observedState: CmuxAgentObservedState? {
        switch self {
        case .unknown: nil
        case .idle: .idle
        case .working: .working
        case .blocked: .blocked
        }
    }
}
