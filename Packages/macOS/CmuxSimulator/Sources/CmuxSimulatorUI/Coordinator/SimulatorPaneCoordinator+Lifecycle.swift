import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    /// Starts ordered command delivery, event observation, and device discovery.
    /// Calling this method more than once is harmless.
    public func start() async {
        guard !closed, !started else { return }
        started = true
        startOutgoingDelivery()
        startEventObservation()

        await reloadDevices()
        guard !Task.isCancelled else {
            if !closed { started = false }
            return
        }
        if status == .idle, let selectedDeviceID {
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
        let locationRouteTeardownTask = beginLocationRouteTeardown()
        let accessibilityRefreshTask = stopAccessibilityOverlayRefresh()
        let liveStatusTask = stopLiveStatusWatcher()
        _ = await accessibilityRefreshTask?.value
        _ = await liveStatusTask?.value
        _ = await locationRouteTeardownTask?.value
        failPendingTextInputCompletions()
        clearWebInspectorState()
        selectionGeneration &+= 1
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
    public func reloadDevices() async {
        do {
            let previousDeviceID = selectedDeviceID
            let discovered = try await client.discoverDevices()
            devices = discovered
                .filter { $0.isAvailable && ($0.family == .iPhone || $0.family == .iPad) }
                .sorted(by: simulatorDeviceOrdering)
            pruneActionHistory(keeping: Set(devices.map(\.id)))
            failure = nil

            if let selectedDeviceID,
               devices.contains(where: { $0.id == selectedDeviceID }) {
                return
            }
            let preferredDevice = preferredDeviceID.flatMap { preferredDeviceID in
                devices.first(where: { $0.id == preferredDeviceID })
            }
            let matchingFallback = devices.first { device in
                let runtimeMatches = preferredRuntimeIdentifier == nil
                    || device.runtimeIdentifier == preferredRuntimeIdentifier
                let typeMatches = preferredDeviceTypeIdentifier == nil
                    || device.deviceTypeIdentifier == preferredDeviceTypeIdentifier
                return runtimeMatches && typeMatches
            }
            let nextDeviceID = preferredDevice?.id
                ?? matchingFallback?.id
                ?? devices.first(where: { $0.state == .booted })?.id
                ?? devices.first?.id
            if previousDeviceID != nil, previousDeviceID != nextDeviceID {
                _ = await beginLocationRouteTeardown()?.value
                guard selectedDeviceID == previousDeviceID else { return }
            }
            selectActionHistory(deviceID: nextDeviceID)
            selectedDeviceID = nextDeviceID
        } catch {
            guard !Task.isCancelled else { return }
            let simulatorFailure = simulatorPaneFailure(from: error, code: "device_discovery_failed")
            failure = simulatorFailure
            status = .failed(simulatorFailure)
        }
    }

    /// Selects, boots, and attaches one Simulator device.
    /// - Parameter id: The CoreSimulator device identifier.
    public func selectDevice(id: String) {
        guard !closed, devices.contains(where: { $0.id == id }) else { return }
        let previousActivation = activationTask
        previousActivation?.cancel()
        let locationRouteTeardownTask = beginLocationRouteTeardown()
        let sessions = detachLongRunningSessions()
        let shouldDisableCamera = !cameraConfiguration.isDisabled
        let outgoingRecoveryTask = outgoingRecoveryTask
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
            _ = await locationRouteTeardownTask?.value
            _ = await outgoingRecoveryTask?.value
            _ = await previousActivation?.value
            await self.stopLongRunningSessions(sessions)
            if shouldDisableCamera {
                _ = try? await client.perform(.configureCamera(.disabled))
            }
            guard !Task.isCancelled, self.selectionGeneration == generation else { return }
            do {
                try await client.activateDevice(id: id, geometry: self.geometry)
                guard !Task.isCancelled, self.selectionGeneration == generation else { return }
                // A Simulator survives its pane and host process. Establish a known
                // orientation instead of trusting stale SimulatorKit metadata left by
                // the previous attachment. Worker-only recovery subsequently replays
                // the latest display orientation tracked by SimulatorWorkerClient.
                await client.send(.rotate(.portrait))
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
        await activationTask.value
        try Task.checkCancellation()
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

    private func startOutgoingDelivery() {
        guard outgoingTask == nil else { return }
        let stream = outgoingStream
        outgoingTask = Task { [client] in
            for await message in stream {
                guard !Task.isCancelled else { return }
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
        let shouldDisableCamera = !cameraConfiguration.isDisabled
        selectionGeneration &+= 1
        let generation = selectionGeneration
        let deviceScopedTasks = clearDeviceScopedState()
        status = .idle
        activationTask = Task { @MainActor [weak self, client] in
            guard let self else { return }
            _ = await deviceScopedTasks.accessibility?.value
            _ = await deviceScopedTasks.liveStatus?.value
            _ = await locationRouteTeardownTask?.value
            _ = await previousActivation?.value
            await self.stopLongRunningSessions(sessions)
            if shouldDisableCamera {
                _ = try? await client.perform(.configureCamera(.disabled))
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
