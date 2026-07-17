import CmuxTerminalRenderer
import Foundation
import GhosttyKit
import os

/// Thread-safe bridge from Ghostty's C callback threads to the worker main actor.
final class GhosttyRendererCallbackContext: @unchecked Sendable {
    private let runtime: Unmanaged<GhosttyRendererWorkerRuntime>
    private let tickScheduled = OSAllocatedUnfairLock(initialState: false)

    init(runtime: GhosttyRendererWorkerRuntime) {
        self.runtime = .passUnretained(runtime)
    }

    func requestTick() {
        let shouldSchedule = tickScheduled.withLock { scheduled in
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard shouldSchedule else { return }

        let runtime = runtime
        Task { @MainActor [tickScheduled] in
            runtime.takeUnretainedValue().tick()
            tickScheduled.withLock { $0 = false }
        }
    }

    func requestFrame(surfaceID: UUID) {
        let runtime = runtime
        Task { @MainActor in
            runtime.takeUnretainedValue().publishFrame(surfaceID: surfaceID)
        }
    }

    func processInput(surfaceID: UUID, data: Data) {
        runtime.takeUnretainedValue().sendProcessInput(surfaceID: surfaceID, data: data)
    }

    func performAction(
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        runtime.takeUnretainedValue().sendAction(target: target, action: action)
    }

    func requestClose(surfaceID: UUID, processAlive: Bool) {
        runtime.takeUnretainedValue().sendCloseRequest(
            surfaceID: surfaceID,
            processAlive: processAlive
        )
    }
}

final class GhosttyRendererSurfaceCallbackContext: @unchecked Sendable {
    let identity: RendererSurfaceIdentity
    let runtime: GhosttyRendererCallbackContext

    init(identity: RendererSurfaceIdentity, runtime: GhosttyRendererCallbackContext) {
        self.identity = identity
        self.runtime = runtime
    }
}
