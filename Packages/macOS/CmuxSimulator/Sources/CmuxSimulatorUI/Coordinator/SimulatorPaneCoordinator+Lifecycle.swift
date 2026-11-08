import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    /// Starts ordered command delivery, event observation, and device discovery.
    /// Calling this method more than once is harmless.
    public func start() async {
        await start(activatingSelectedDevice: true)
    }

    /// Starts discovery and worker event delivery without activating the
    /// persisted or default device before an explicit selection request.
    public func prepareForExplicitDeviceSelection() async {
        await start(activatingSelectedDevice: false)
    }

    private func start(activatingSelectedDevice: Bool) async {
        if let startupTask {
            await waitForPaneOwnedTask(startupTask)
            return
        }
        guard !closed, !started else { return }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.runStartup(activatingSelectedDevice: activatingSelectedDevice)
        }
        startupTask = task
        await waitForPaneOwnedTask(task)
        guard !Task.isCancelled else { return }
        await task.value
        startupTask = nil
    }

    private func waitForPaneOwnedTask(_ task: Task<Void, Never>) async {
        let receipt = SimulatorStartupWaitReceipt()
        Task {
            await task.value
            receipt.finish()
        }
        await withTaskCancellationHandler {
            await receipt.wait()
        } onCancel: {
            receipt.finish()
        }
    }

    /// Waits for the currently selected device to finish its pane-owned
    /// activation without transferring cancellation ownership to the caller.
    public func waitForSelectedDeviceStreaming() async throws {
        if status == .streaming { return }
        guard let selectedDeviceID,
              devices.contains(where: { $0.id == selectedDeviceID }) else {
            throw SimulatorFailure(
                code: "device_not_found",
                message: String(
                    localized: "cli.simulator.error.deviceRequired",
                    defaultValue: "The Simulator pane has no selected device"
                ),
                isRecoverable: true
            )
        }
        if activationTask == nil {
            selectDevice(id: selectedDeviceID)
        }
        guard let activationTask else {
            throw SimulatorFailure(
                code: "worker_unavailable",
                message: String(
                    localized: "simulator.failure.rendererStopped",
                    defaultValue: "The Simulator renderer stopped"
                ),
                isRecoverable: true
            )
        }
        await waitForPaneOwnedTask(activationTask)
        try Task.checkCancellation()
        guard self.selectedDeviceID == selectedDeviceID, status == .streaming else {
            throw failure ?? SimulatorFailure(
                code: "simulator_device_selection_failed",
                message: String(
                    localized: "cli.ios.error.deviceSelectionFailed",
                    defaultValue: "The requested iOS Simulator device did not start streaming"
                ),
                isRecoverable: true
            )
        }
    }

    private func runStartup(activatingSelectedDevice: Bool) async {
        guard !closed, !started else { return }
        started = true
        startOutgoingDelivery()
        startEventObservation()

        await reloadDevices()
        guard !Task.isCancelled else {
            if !closed { started = false }
            return
        }
        if activatingSelectedDevice, status == .idle, let selectedDeviceID {
            selectDevice(id: selectedDeviceID)
        }
    }

    /// Permanently closes this coordinator and its isolated worker without
    /// shutting down the selected CoreSimulator device.
    public func stop() async {
        await close()
    }

    /// Permanently closes this coordinator. Activation is cancelled and
    /// joined before the client stops, preventing a late activation from
    /// respawning the worker after panel teardown.
    public func close() async {
        guard !closed else { return }
        closed = true
        let controlActionTasks = cancelControlActions()
        for task in controlActionTasks { await task.value }
        let locationRouteTeardownTask = beginLocationRouteTeardown()
        let accessibilityRefreshTask = stopAccessibilityOverlayRefresh()
        let liveStatusTask = stopLiveStatusWatcher()
        _ = await accessibilityRefreshTask?.value
        _ = await liveStatusTask?.value
        _ = await locationRouteTeardownTask?.value
        failPendingTextInputCompletions()
        clearWebInspectorState()
        resetCapabilityHydration()
        selectionGeneration &+= 1
        let startupTask = startupTask
        self.startupTask = nil
        startupTask?.cancel()
        _ = await startupTask?.value
        let activationTask = activationTask
        self.activationTask = nil
        activationTask?.cancel()
        _ = await activationTask?.value
        chromeTask?.cancel()
        if let videoSession { await videoSession.stopAndWait() }
        if let logSession { await logSession.stopAndWait() }
        videoSession = nil
        logSession = nil
        isVideoRecording = false
        isStreamingLogs = false
        eventsTask?.cancel()
        eventsTask = nil
        outgoingTask?.cancel()
        outgoingTask = nil
        outgoingContinuation.finish()
        let outgoingRecoveryTask = outgoingRecoveryTask
        outgoingRecoveryGeneration &+= 1
        self.outgoingRecoveryTask = nil
        _ = await outgoingRecoveryTask?.value
        if !cameraConfiguration.isDisabled {
            _ = try? await client.perform(.configureCamera(.disabled))
            cameraConfiguration = .disabled
        }
        await client.send(.releaseInputs)
        await client.stop()
        frameTransport = nil
        status = .idle
    }

    /// Refreshes the device picker from CoreSimulator discovery.
    @discardableResult
    public func reloadDevices() async -> Bool {
        let selectionGeneration = selectionGeneration
        deviceDiscoveryGeneration &+= 1
        let discoveryGeneration = deviceDiscoveryGeneration
        do {
            let previousDeviceID = selectedDeviceID
            let wasAwaitingExplicitSelection = requiresExplicitDeviceSelection
                && previousDeviceID == nil
                && failure?.code == "simulator_saved_device_unavailable"
            let discovered = try await client.discoverDevices()
            guard !closed,
                  !Task.isCancelled,
                  self.selectionGeneration == selectionGeneration,
                  deviceDiscoveryGeneration == discoveryGeneration else { return false }
            devices = discovered
                .filter { $0.isAvailable && ($0.family == .iPhone || $0.family == .iPad) }
                .sorted(by: simulatorDeviceOrdering)
            pruneActionHistory(keeping: Set(devices.map(\.id)))
            if wasAwaitingExplicitSelection { return true }
            failure = nil

            if let selectedDeviceID,
               devices.contains(where: { $0.id == selectedDeviceID }) {
                return true
            }
            if previousDeviceID == nil,
               let preferredDeviceID,
               devices.contains(where: { $0.id == preferredDeviceID }) {
                selectActionHistory(deviceID: preferredDeviceID)
                selectedDeviceID = preferredDeviceID
                return true
            }
            if requiresExplicitDeviceSelection || previousDeviceID != nil || preferredDeviceID != nil {
                // Runtime and device type are descriptive, non-unique metadata. Never
                // substitute them for a missing persisted UDID because automation could
                // silently target a different Simulator without an explicit selection.
                await failClosedForUnavailableDevice()
                return true
            }
            let nextDeviceID = devices.first(where: { $0.state == .booted })?.id
                ?? devices.first?.id
            selectActionHistory(deviceID: nextDeviceID)
            selectedDeviceID = nextDeviceID
            return true
        } catch {
            guard !closed,
                  !Task.isCancelled,
                  self.selectionGeneration == selectionGeneration,
                  deviceDiscoveryGeneration == discoveryGeneration else { return false }
            let simulatorFailure = simulatorPaneFailure(from: error, code: "device_discovery_failed")
            failure = simulatorFailure
            if status != .streaming {
                status = .failed(simulatorFailure)
            }
            return true
        }
    }

    private func failClosedForUnavailableDevice() async {
        let previousActivation = activationTask
        previousActivation?.cancel()
        activationTask = nil
        let locationRouteTeardownTask = beginLocationRouteTeardown()
        let sessions = detachLongRunningSessions()
        let shouldDisableCamera = !cameraConfiguration.isDisabled
        let deviceScopedTasks = clearDeviceScopedState()
        selectionGeneration &+= 1
        requiresExplicitDeviceSelection = true
        selectActionHistory(deviceID: nil)
        selectedDeviceID = nil
        chromeProfile = nil
        let unavailable = SimulatorFailure(
            code: "simulator_saved_device_unavailable",
            message: String(
                localized: "simulator.failure.savedDeviceUnavailable",
                defaultValue: "The saved Simulator is no longer available. Choose another device."
            ),
            isRecoverable: true
        )
        failure = unavailable
        status = .failed(unavailable)

        let previousRecovery = outgoingRecoveryTask
        let cleanup = Task { @MainActor [weak self, client] in
            _ = await previousRecovery?.value
            _ = await deviceScopedTasks.accessibility?.value
            _ = await deviceScopedTasks.liveStatus?.value
            _ = await locationRouteTeardownTask?.value
            _ = await previousActivation?.value
            if let self { await self.stopLongRunningSessions(sessions) }
            if shouldDisableCamera {
                _ = try? await client.perform(.configureCamera(.disabled))
            }
            await client.invalidateWorker()
        }
        outgoingRecoveryGeneration &+= 1
        outgoingRecoveryTask = cleanup
        await cleanup.value
    }

    /// Selects, boots, and attaches one Simulator device.
    /// - Parameter id: The CoreSimulator device identifier.
    public func selectDevice(id: String) {
        explicitSelectionRequestGeneration &+= 1
        selectDeviceForCurrentRequest(id: id)
    }

    private func selectDeviceForCurrentRequest(id: String) {
        guard !closed, devices.contains(where: { $0.id == id }) else { return }
        requiresExplicitDeviceSelection = false
        let previousActivation = activationTask
        previousActivation?.cancel()
        let controlActionTasks = cancelControlActions()
        let locationRouteTeardownTask = Task { @MainActor [weak self] in
            for task in controlActionTasks { await task.value }
            guard let self else { return }
            _ = await self.beginLocationRouteTeardown()?.value
        }
        let sessions = detachLongRunningSessions()
        let previousCameraConfiguration = cameraConfiguration
        let shouldDisableCamera = !previousCameraConfiguration.isDisabled
        let outgoingRecoveryTask = outgoingRecoveryTask
        outgoingRecoveryGeneration &+= 1
        self.outgoingRecoveryTask = nil
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selectActionHistory(deviceID: id)
        selectedDeviceID = id
        let deviceScopedTasks = clearDeviceScopedState()
        chromeProfile = nil
        loadChrome(for: id)
        status = .connecting
        activationTask = Task { @MainActor [weak self, client] in
            guard let self else { return }
            _ = await deviceScopedTasks.accessibility?.value
            _ = await deviceScopedTasks.liveStatus?.value
            await locationRouteTeardownTask.value
            guard self.locationRouteDeviceID == nil else {
                if let failure = self.failure { self.status = .failed(failure) }
                return
            }
            _ = await outgoingRecoveryTask?.value
            _ = await previousActivation?.value
            await self.stopLongRunningSessions(sessions)
            if shouldDisableCamera {
                do {
                    _ = try await client.perform(.configureCamera(.disabled))
                } catch {
                    self.cameraConfiguration = previousCameraConfiguration
                    let failure = simulatorPaneFailure(from: error, code: "camera_cleanup_failed")
                    self.failure = failure
                    self.status = .failed(failure)
                    return
                }
            }
            guard !Task.isCancelled, self.selectionGeneration == generation else { return }
            do {
                try await client.activateDevice(id: id, geometry: self.geometry)
                guard !Task.isCancelled, self.selectionGeneration == generation else { return }
                // A Simulator survives its pane and host process. Establish a known
                // orientation instead of trusting stale SimulatorKit metadata left by
                // the previous attachment. Worker-only recovery subsequently replays
                // the latest display orientation tracked by SimulatorWorkerClient.
                if let synchronizedDisplay = try await client.synchronizeOrientation(.portrait) {
                    self.display = synchronizedDisplay
                }
                self.failure = nil
                self.status = .streaming
            } catch is CancellationError {
                return
            } catch {
                guard self.selectionGeneration == generation else { return }
                let simulatorFailure = simulatorPaneFailure(from: error, code: "device_activation_failed")
                self.failure = simulatorFailure
                self.status = .failed(simulatorFailure)
            }
        }
    }

    /// Selects one discovered device and waits for its attachment to finish.
    public func selectDeviceAndWait(id: String) async throws {
        let previousDeviceID = selectedDeviceID
        let initialSelectionGeneration = selectionGeneration
        explicitSelectionRequestGeneration &+= 1
        let requestGeneration = explicitSelectionRequestGeneration
        while !(await reloadDevices()) {
            try Task.checkCancellation()
            guard !closed,
                  explicitSelectionRequestGeneration == requestGeneration else {
                throw CancellationError()
            }
        }
        do {
            try Task.checkCancellation()
        } catch {
            restoreSelectionAfterCancellation(
                previousDeviceID: previousDeviceID,
                generation: initialSelectionGeneration
            )
            throw CancellationError()
        }
        guard explicitSelectionRequestGeneration == requestGeneration else {
            throw CancellationError()
        }
        guard devices.contains(where: { $0.id == id }) else {
            throw SimulatorFailure(
                code: "simulator_device_not_found",
                message: String(
                    localized: "cli.ios.error.deviceNotFound",
                    defaultValue: "The requested iOS Simulator device was not found"
                ),
                isRecoverable: false
            )
        }
        selectDeviceForCurrentRequest(id: id)
        let selectionTask = activationTask
        let generation = selectionGeneration
        if let selectionTask {
            do {
                try await awaitActivationTask(selectionTask, generation: generation)
            } catch is CancellationError {
                if selectedDeviceID == id, status == .streaming { return }
                restoreSelectionAfterCancellation(
                    previousDeviceID: previousDeviceID,
                    generation: generation
                )
                throw CancellationError()
            }
        }
        guard explicitSelectionRequestGeneration == requestGeneration else {
            throw CancellationError()
        }
        guard selectedDeviceID == id, status == .streaming else {
            throw failure ?? SimulatorFailure(
                code: "simulator_device_selection_failed",
                message: String(
                    localized: "cli.ios.error.deviceSelectionFailed",
                    defaultValue: "The requested iOS Simulator device did not start streaming"
                ),
                isRecoverable: true
            )
        }
    }

    private func restoreSelectionAfterCancellation(
        previousDeviceID: String?,
        generation: UInt64
    ) {
        guard selectionGeneration == generation, selectedDeviceID != previousDeviceID else { return }
        if let previousDeviceID,
           devices.contains(where: { $0.id == previousDeviceID }) {
            selectDevice(id: previousDeviceID)
            return
        }
        selectionGeneration &+= 1
        activationTask?.cancel()
        activationTask = nil
        selectActionHistory(deviceID: nil)
        selectedDeviceID = nil
        status = .idle
    }

    /// Reboots the worker connection for the selected device.
    public func recover() {
        Task { @MainActor [weak self] in
            try? await self?.recoverAndWait()
        }
    }

    /// Reboots the selected worker and returns only after attachment succeeds.
    public func recoverAndWait() async throws {
        guard !closed else {
            throw SimulatorFailure(
                code: "simulator_closed",
                message: String(
                    localized: "cli.simulator.error.paneClosed",
                    defaultValue: "The Simulator pane closed before the operation started"
                ),
                isRecoverable: false
            )
        }
        restartOutgoingDelivery()
        restartEventObservation()
        if selectedDeviceID == nil
            || !devices.contains(where: { $0.id == selectedDeviceID }) {
            await reloadDevices()
        }
        guard let selectedDeviceID,
              devices.contains(where: { $0.id == selectedDeviceID }) else {
            throw SimulatorFailure(
                code: "device_not_found",
                message: String(
                    localized: "cli.simulator.error.deviceRequired",
                    defaultValue: "The Simulator pane has no selected device"
                ),
                isRecoverable: true
            )
        }
        selectDevice(id: selectedDeviceID)
        guard let activationTask else {
            throw SimulatorFailure(
                code: "worker_unavailable",
                message: String(
                    localized: "simulator.failure.rendererStopped",
                    defaultValue: "The Simulator renderer stopped"
                ),
                isRecoverable: true
            )
        }
        let generation = selectionGeneration
        do {
            try await awaitActivationTask(activationTask, generation: generation)
        } catch is CancellationError {
            if !closed,
               self.selectedDeviceID == selectedDeviceID,
               selectionGeneration == generation,
               status == .streaming {
                return
            }
            throw CancellationError()
        }
        guard !closed, self.selectedDeviceID == selectedDeviceID else {
            throw CancellationError()
        }
        guard status == .streaming else {
            throw failure ?? SimulatorFailure(
                code: "worker_unavailable",
                message: String(
                    localized: "simulator.failure.rendererStopped",
                    defaultValue: "The Simulator renderer stopped"
                ),
                isRecoverable: true
            )
        }
    }

    private func awaitActivationTask(
        _ task: Task<Void, Never>,
        generation: UInt64
    ) async throws {
        do {
            try await withTaskCancellationHandler {
                await task.value
                try Task.checkCancellation()
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            if selectionGeneration == generation, status == .connecting {
                activationTask = nil
                status = .idle
            }
            throw CancellationError()
        }
    }

    private func startOutgoingDelivery() {
        guard outgoingTask == nil else { return }
        let stream = outgoingStream
        outgoingTask = Task { @MainActor [weak self, client] in
            for await message in stream {
                guard !Task.isCancelled, let self else { return }
                while true {
                    let recoveryGeneration = self.outgoingRecoveryGeneration
                    let recoveryTask = self.outgoingRecoveryTask
                    _ = await recoveryTask?.value
                    guard !Task.isCancelled else { return }
                    if self.outgoingRecoveryGeneration == recoveryGeneration { break }
                }
                if case let .typeText(requestID, _) = message,
                   self.cancelledTextInputRequestIDs.remove(requestID) != nil {
                    continue
                }
                if case let .typeText(requestID, _) = message,
                   self.status != .streaming {
                    self.textInputCompletions.removeValue(forKey: requestID)?(false)
                    continue
                }
                await client.send(message)
            }
        }
    }

    private func restartOutgoingDelivery() {
        outgoingContinuation.finish()
        let previousDeliveryTask = outgoingTask
        outgoingTask = nil
        previousDeliveryTask?.cancel()
        if let previousDeliveryTask {
            let previousRecoveryTask = outgoingRecoveryTask
            outgoingRecoveryGeneration &+= 1
            outgoingRecoveryTask = Task {
                _ = await previousDeliveryTask.value
                _ = await previousRecoveryTask?.value
            }
        }
        let (stream, continuation) = AsyncStream.makeStream(
            of: SimulatorWorkerInbound.self,
            bufferingPolicy: .bufferingOldest(Self.maximumOutgoingMessageCount)
        )
        outgoingStream = stream
        outgoingContinuation = continuation
        outgoingOverflowed = false
        cancelledTextInputRequestIDs.removeAll()
        startOutgoingDelivery()
    }

    private func startEventObservation() {
        guard eventsTask == nil else { return }
        eventsTask = makeEventObservationTask()
    }

    private func restartEventObservation() {
        eventsTask?.cancel()
        eventsTask = makeEventObservationTask()
    }

    private func makeEventObservationTask() -> Task<Void, Never> {
        Task { @MainActor [weak self, client] in
            // One automatic worker restart is allowed by the client. A fused
            // session stops after two streams; explicit recovery installs a
            // fresh task and a fresh subscription generation.
            for attempt in 0...1 {
                let events = await client.subscribe()
                for await event in events {
                    guard !Task.isCancelled, let self else { return }
                    self.receive(event)
                }
                guard !Task.isCancelled, let self else { return }
                self.receive(.workerStopped)
                if attempt == 1 { return }
            }
        }
    }

    /// Shuts down the selected device and returns the pane to its idle state.
    public func shutdownSelectedDevice() {
        guard let selectedDeviceID else { return }
        let previousActivation = activationTask
        previousActivation?.cancel()
        let locationRouteTeardownTask = beginLocationRouteTeardown()
        let sessions = detachLongRunningSessions()
        let previousCameraConfiguration = cameraConfiguration
        let shouldDisableCamera = !previousCameraConfiguration.isDisabled
        selectionGeneration &+= 1
        let generation = selectionGeneration
        let deviceScopedTasks = clearDeviceScopedState()
        status = .idle
        activationTask = Task { @MainActor [weak self, client] in
            guard let self else { return }
            _ = await deviceScopedTasks.accessibility?.value
            _ = await deviceScopedTasks.liveStatus?.value
            _ = await locationRouteTeardownTask?.value
            guard self.locationRouteDeviceID == nil else {
                if let failure = self.failure { self.status = .failed(failure) }
                return
            }
            _ = await previousActivation?.value
            await self.stopLongRunningSessions(sessions)
            if shouldDisableCamera {
                do {
                    _ = try await client.perform(.configureCamera(.disabled))
                } catch {
                    self.cameraConfiguration = previousCameraConfiguration
                    let failure = simulatorPaneFailure(from: error, code: "camera_cleanup_failed")
                    self.failure = failure
                    self.status = .failed(failure)
                    return
                }
            }
            guard !Task.isCancelled, self.selectionGeneration == generation else { return }
            do {
                self.enqueue(.releaseInputs)
                try await client.shutdownDevice(id: selectedDeviceID)
                self.status = .idle
                self.frameTransport = nil
                self.display = nil
                await self.reloadDevices()
            } catch is CancellationError {
                return
            } catch {
                guard self.selectionGeneration == generation else { return }
                let simulatorFailure = simulatorPaneFailure(from: error, code: "device_shutdown_failed")
                self.failure = simulatorFailure
                self.status = .failed(simulatorFailure)
            }
        }
    }

    private func detachLongRunningSessions() -> (
        video: SimulatorProcessSession?,
        log: SimulatorProcessSession?
    ) {
        let sessions = (videoSession, logSession)
        videoSession = nil
        logSession = nil
        isVideoRecording = false
        isStreamingLogs = false
        return sessions
    }

    private func stopLongRunningSessions(_ sessions: (
        video: SimulatorProcessSession?,
        log: SimulatorProcessSession?
    )) async {
        if let video = sessions.video { await video.stopAndWait() }
        if let log = sessions.log { await log.stopAndWait() }
    }

    private func clearDeviceScopedState() -> (
        accessibility: Task<Void, Never>?,
        liveStatus: Task<Void, Never>?
    ) {
        let accessibilityRefreshTask = stopAccessibilityOverlayRefresh()
        let liveStatusTask = stopLiveStatusWatcher()
        failPendingTextInputCompletions()
        failure = nil
        controlFailure = nil
        display = nil
        frameTransport = nil
        capabilities = [.userInterfaceSettings]
        resetCapabilityHydration()
        foregroundApplication = nil
        accessibilitySnapshot = nil
        accessibilityRows = []
        highlightedAccessibilityNodeID = nil
        accessibilityOverlaySelectedNodeID = nil
        clearWebInspectorState()
        installedApplications = []
        userInstalledApplications = []
        clipboardText = ""
        recentLogsText = ""
        liveLogsText = ""
        privacySnapshot = nil
        interfaceStatus = nil
        cameraStatus = nil
        cameraConfiguration = .disabled
        locationRouteIsActive = false
        locationRouteIsPaused = false
        return (accessibilityRefreshTask, liveStatusTask)
    }

    private func loadChrome(for deviceID: String) {
        chromeTask?.cancel()
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            chromeProfile = nil
            return
        }
        chromeTask = Task { @MainActor [weak self, chromeLoader] in
            let profile = await chromeLoader.load(deviceTypeIdentifier: device.deviceTypeIdentifier)
            guard !Task.isCancelled, let self, self.selectedDeviceID == deviceID else { return }
            self.chromeProfile = profile
            if profile != nil {
                self.capabilities.insert(.deviceChrome)
            } else {
                self.capabilities.remove(.deviceChrome)
            }
        }
    }

}

private func simulatorDeviceOrdering(_ lhs: SimulatorDevice, _ rhs: SimulatorDevice) -> Bool {
    if lhs.state == .booted, rhs.state != .booted { return true }
    if rhs.state == .booted, lhs.state != .booted { return false }
    if lhs.family != rhs.family { return lhs.family == .iPhone }
    if lhs.lastBootedAt != rhs.lastBootedAt {
        return (lhs.lastBootedAt ?? .distantPast) > (rhs.lastBootedAt ?? .distantPast)
    }
    if lhs.runtimeName != rhs.runtimeName { return lhs.runtimeName > rhs.runtimeName }
    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
}
