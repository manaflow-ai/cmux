import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    /// Suspends foreground-app and camera liveness reads while the pane is hidden.
    public func setLiveStatusVisibility(_ isVisible: Bool) {
        guard liveStatusIsVisible != isVisible else { return }
        liveStatusIsVisible = isVisible
        updateLiveStatusWatcher()
    }

    func updateLiveStatusWatcher() {
        let supportsLiveStatus = capabilities.contains(.foregroundApplication)
            || capabilities.contains(.cameraInjection)
        let shouldPoll = !closed
            && liveStatusIsVisible
            && status == .streaming
            && supportsLiveStatus
        guard liveStatusPollingActive != shouldPoll else { return }
        liveStatusPollingActive = shouldPoll
        replaceLiveStatusTask(shouldPoll: shouldPoll)
    }

    @discardableResult
    func stopLiveStatusWatcher() -> Task<Void, Never>? {
        liveStatusPollingActive = false
        return replaceLiveStatusTask(shouldPoll: false)
    }

    @discardableResult
    private func replaceLiveStatusTask(shouldPoll: Bool) -> Task<Void, Never>? {
        liveStatusGeneration &+= 1
        let generation = liveStatusGeneration
        let previous = liveStatusTask
        previous?.cancel()
        guard shouldPoll else {
            liveStatusTask = previous.map { previous in
                Task { _ = await previous.value }
            }
            return liveStatusTask
        }

        let sleeper = webInspectorSleeper
        liveStatusTask = Task { @MainActor [weak self] in
            _ = await previous?.value
            while !Task.isCancelled {
                guard let self,
                      self.liveStatusPollingActive,
                      self.liveStatusGeneration == generation else { return }
                let succeeded = await self.refreshLiveStatus(generation: generation)
                do {
                    try await sleeper.sleep(for: succeeded ? .seconds(1) : .seconds(5))
                } catch {
                    return
                }
            }
        }
        return liveStatusTask
    }

    private func refreshLiveStatus(generation: UInt64) async -> Bool {
        let selectionGeneration = selectionGeneration
        let requestedCapabilities = capabilities
        var attempted = false
        var succeeded = true

        if requestedCapabilities.contains(.foregroundApplication) {
            attempted = true
            do {
                let result = try await client.perform(.readForegroundApplication)
                guard liveStatusResultIsCurrent(
                    generation: generation,
                    selectionGeneration: selectionGeneration
                ), case let .foregroundApplication(application) = result else { return false }
                if foregroundApplication != application { foregroundApplication = application }
            } catch {
                succeeded = false
            }
        }

        if requestedCapabilities.contains(.cameraInjection) {
            attempted = true
            do {
                let result = try await client.perform(.readCameraStatus)
                guard liveStatusResultIsCurrent(
                    generation: generation,
                    selectionGeneration: selectionGeneration
                ), case let .cameraStatus(status) = result else { return false }
                if cameraStatus != status {
                    cameraStatus = status
                    cameraConfiguration = status.configuration
                }
            } catch {
                succeeded = false
            }
        }
        return attempted && succeeded
    }

    private func liveStatusResultIsCurrent(
        generation: UInt64,
        selectionGeneration: UInt64
    ) -> Bool {
        !Task.isCancelled
            && !closed
            && liveStatusGeneration == generation
            && self.selectionGeneration == selectionGeneration
            && liveStatusPollingActive
    }
}
