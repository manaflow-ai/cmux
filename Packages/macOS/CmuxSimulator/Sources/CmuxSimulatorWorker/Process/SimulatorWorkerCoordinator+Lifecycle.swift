import CmuxSimulator
import Foundation
import os

extension SimulatorWorkerCoordinator {
    func prepareForProcessExit() {
        cancelForegroundApplicationRequests()
        cancelAccessibilitySnapshotRequests()
        cancelToolOperationsWithoutWaiting()
        deviceStateMonitor?.invalidate()
        deviceStateMonitor = nil
        attachedDevice = nil
        deviceStateGate.reset()
        scrollWheel?.cancel()
        scrollWheel = nil
        hid?.releaseInputs()
        hid = nil
        framebuffer?.stop()
        framebuffer = nil
        camera.stop()
        webInspector.shutdown()
        currentDisplay = nil
        currentFrameTransport = nil
        currentDeviceIdentifier = nil
        gestureStart = nil
        gestureUsesTwoFingers = false
        pendingKeyUsages.removeAll()
    }

    func shutdown() async {
        cancelForegroundApplicationRequests()
        cancelAccessibilitySnapshotRequests()
        await cancelToolOperations()
        deviceStateMonitor?.invalidate()
        deviceStateMonitor = nil
        attachedDevice = nil
        deviceStateGate.reset()
        scrollWheel?.cancel()
        scrollWheel = nil
        hid?.releaseInputs()
        hid = nil
        framebuffer?.stop()
        framebuffer = nil
        await accessibilityExecutor.detach()
        await camera.shutdown()
        try? await webInspector.releaseSession(emit: false)
        webInspector.shutdown()
        currentDisplay = nil
        currentFrameTransport = nil
        currentDeviceIdentifier = nil
        gestureStart = nil
        gestureUsesTwoFingers = false
        pendingKeyUsages.removeAll()
    }

    func attach(udid: String) async {
        await shutdown()
        send(.status(.connecting))
        do {
            if !frameworksLoaded {
                try frameworkLoader.load()
                frameworksLoaded = true
            }
            let resolver: SimulatorDeviceResolver
            if let existing = self.resolver {
                resolver = existing
            } else {
                resolver = SimulatorDeviceResolver(
                    developerDirectory: frameworkLoader.developerDirectory
                )
                self.resolver = resolver
            }
            let device = try resolver.device(udid: udid)
            try resolver.requireBooted(device)

            let framebuffer = SimulatorFramebuffer(
                onFrameTransportChange: { [weak self] transport in
                    guard let self else { return }
                    currentFrameTransport = transport
                    send(.frameTransport(transport))
                },
                onDisplayChange: { [weak self] display in
                    guard let self else { return }
                    if self.currentDisplay != display {
                        self.cancelAccessibilitySnapshotRequests()
                    }
                    self.currentDisplay = display
                    self.send(.display(display))
                })
            try await framebuffer.start(device: device)

            let hid = SimulatorHIDTransport(frameworkLoader: frameworkLoader)
            var hidFailure: Error?
            do {
                try hid.attach(device: device)
                self.hid = hid
                scrollWheel = SimulatorScrollWheelController(
                    sender: { [weak hid] event in hid?.send(event) == true },
                    sleeper: hid.sleeper,
                    completion: { [weak self] eventIdentifier in
                        self?.send(.scrollWheelEnded(eventID: eventIdentifier))
                    }
                )
            } catch {
                hidFailure = error
                self.hid = nil
                scrollWheel = nil
            }
            let accessibilityAvailable = await accessibilityExecutor.attach(
                device: SimulatorAccessibilityDevice(device)
            )
            camera.attach(deviceIdentifier: udid)
            let webInspectorAvailable = await webInspector.isAvailable(deviceIdentifier: udid)

            self.framebuffer = framebuffer
            attachedDevice = device
            currentDeviceIdentifier = udid
            try startDeviceStateMonitoring(device: device, deviceIdentifier: udid)
            var probe: SimulatorWorkerCapabilityProbe
            if self.hid != nil {
                probe = hid.capabilities(
                    framebufferAvailable: true,
                    accessibilityAvailable: accessibilityAvailable,
                    cameraAvailable: camera.isAvailable
                )
            } else {
                probe = SimulatorWorkerCapabilityProbe(
                    hasFramebuffer: true,
                    hasAccessibility: accessibilityAvailable,
                    hasForegroundApplication: accessibilityAvailable,
                    hasCameraInjection: camera.isAvailable,
                    hasExtendedPermissions: privacy.isAvailable
                )
            }
            probe.hasExtendedPermissions = privacy.isAvailable
            probe.hasWebInspector = webInspectorAvailable
            send(.capabilities(probe.capabilities))
            if let hidFailure {
                report(hidFailure)
            }
            send(.status(.streaming))
            coordinatorLogger.info("Attached Simulator worker to device \(udid, privacy: .public)")
        } catch let error as SimulatorWorkerFailure {
            await shutdown()
            let failure = error.processSafeValue
            send(.failure(failure))
            switch error {
            case .deviceNotFound, .deviceNotBooted:
                send(.status(.deviceUnavailable))
            default:
                send(.status(.failed(failure)))
            }
            coordinatorLogger.error(
                "Simulator worker attach failed: \(failure.message, privacy: .public)")
        } catch {
            await shutdown()
            let failure = SimulatorFailure(
                code: "worker_attach_failed",
                message: error.localizedDescription,
                isRecoverable: true
            )
            send(.failure(failure))
            send(.status(.failed(failure)))
            coordinatorLogger.error(
                "Simulator worker attach failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startDeviceStateMonitoring(
        device: NSObject,
        deviceIdentifier: String
    ) throws {
        deviceStateMonitor?.invalidate()
        deviceStateMonitor = nil
        deviceStateGate.reset()
        let initialState =
            objectProperty(device, selectorName: "stateString") as? String
            ?? "Unknown"
        guard initialState.caseInsensitiveCompare("Booted") == .orderedSame else {
            throw SimulatorWorkerFailure.deviceNotBooted(
                "Simulator changed to \(initialState) before state monitoring began."
            )
        }
        _ = deviceStateGate.observe(state: initialState)
        let monitor = try SimulatorDeviceStateMonitor(
            device: device
        ) { [weak self, weak device] in
            guard let self, let device,
                self.attachedDevice === device,
                self.currentDeviceIdentifier == deviceIdentifier
            else {
                return
            }
            let state =
                objectProperty(device, selectorName: "stateString") as? String
                ?? "Unknown"
            guard let transition = self.deviceStateGate.observe(state: state) else { return }
            self.handleDeviceStateTransition(
                transition,
                device: device,
                deviceIdentifier: deviceIdentifier
            )
        }
        let registeredState =
            objectProperty(device, selectorName: "stateString") as? String
            ?? "Unknown"
        guard attachedDevice === device,
            currentDeviceIdentifier == deviceIdentifier,
            registeredState.caseInsensitiveCompare("Booted") == .orderedSame
        else {
            monitor.invalidate()
            throw SimulatorWorkerFailure.deviceNotBooted(
                "Simulator changed to \(registeredState) while state monitoring started."
            )
        }
        deviceStateMonitor = monitor
    }

    private func handleDeviceStateTransition(
        _ transition: SimulatorDeviceStateTransition,
        device: NSObject,
        deviceIdentifier: String
    ) {
        guard attachedDevice === device,
            currentDeviceIdentifier == deviceIdentifier
        else {
            return
        }
        let state: String =
            switch transition {
            case .becameUnavailable(let state): state
            }

        deviceStateMonitor?.invalidate()
        deviceStateMonitor = nil
        cancelForegroundApplicationRequests()
        cancelAccessibilitySnapshotRequests()
        cancelToolOperationsWithoutWaiting()
        attachedDevice = nil
        scrollWheel?.cancel()
        scrollWheel = nil
        hid?.releaseInputs()
        hid = nil
        framebuffer?.stop()
        framebuffer = nil
        let accessibilityExecutor = self.accessibilityExecutor
        Task { await accessibilityExecutor.detach() }
        currentDisplay = nil
        currentFrameTransport = nil
        currentDeviceIdentifier = nil
        gestureStart = nil
        gestureUsesTwoFingers = false
        pendingKeyUsages.removeAll()
        camera.detachFromUnavailableDevice()
        webInspector.shutdown()

        let failure = SimulatorFailure(
            code: "simulator_device_unavailable",
            message: String(
                localized: "simulator.failure.deviceStateChanged",
                defaultValue: "Simulator \(deviceIdentifier) changed to \(state)."
            ),
            isRecoverable: true
        )
        send(.capabilities([]))
        send(.failure(failure))
        send(.status(.deviceUnavailable))
        coordinatorLogger.info(
            "Detached unavailable Simulator \(deviceIdentifier, privacy: .public) in state \(state, privacy: .public)"
        )
    }
}
