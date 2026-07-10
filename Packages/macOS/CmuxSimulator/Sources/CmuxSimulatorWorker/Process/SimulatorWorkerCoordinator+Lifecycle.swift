import CmuxSimulator
import Foundation
import os

extension SimulatorWorkerCoordinator {
    func shutdown() async {
        deviceStateMonitor?.invalidate()
        deviceStateMonitor = nil
        attachedDevice = nil
        deviceStateGate.reset()
        hid?.releaseInputs()
        hid = nil
        framebuffer?.stop()
        framebuffer = nil
        accessibility.detach()
        await camera.shutdown()
        webInspector.shutdown()
        renderContext = nil
        currentDisplay = nil
        currentDeviceIdentifier = nil
        gestureStart = nil
        gestureUsesTwoFingers = false
        pendingKeyUsages.removeAll()
    }

    func attach(udid: String, geometry: SimulatorSurfaceGeometry?) async {
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

            let renderContext = try SimulatorRemoteRenderContext()
            let initialGeometry = geometry ?? SimulatorSurfaceGeometry(
                width: 430,
                height: 932,
                scale: 2
            )
            renderContext.resize(initialGeometry)

            let framebuffer = SimulatorFramebuffer(
                renderContext: renderContext
            ) { [weak self] display in
                guard let self else { return }
                self.currentDisplay = display
                self.send(.display(display))
            }
            try framebuffer.start(device: device)
            framebuffer.resize(initialGeometry)

            let hid = SimulatorHIDTransport(frameworkLoader: frameworkLoader)
            var hidFailure: Error?
            do {
                try hid.attach(device: device)
                self.hid = hid
            } catch {
                hidFailure = error
                self.hid = nil
            }
            let accessibilityAvailable = accessibility.attach(device: device)
            camera.attach(deviceIdentifier: udid)
            let webInspectorAvailable = await webInspector.isAvailable(deviceIdentifier: udid)

            self.renderContext = renderContext
            self.framebuffer = framebuffer
            attachedDevice = device
            currentDeviceIdentifier = udid
            try startDeviceStateMonitoring(device: device, deviceIdentifier: udid)
            send(.context(renderContext.contextIdentifier))

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
            coordinatorLogger.error("Simulator worker attach failed: \(failure.message, privacy: .public)")
        } catch {
            await shutdown()
            let failure = SimulatorFailure(
                code: "worker_attach_failed",
                message: error.localizedDescription,
                isRecoverable: true
            )
            send(.failure(failure))
            send(.status(.failed(failure)))
            coordinatorLogger.error("Simulator worker attach failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func foregroundSpringBoard(deviceIdentifier: String) async -> Bool {
        guard let result = try? await subprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "simctl", "launch", deviceIdentifier, "com.apple.springboard",
            ]
        ) else {
            return false
        }
        return result.status == 0
    }

    private func startDeviceStateMonitoring(
        device: NSObject,
        deviceIdentifier: String
    ) throws {
        deviceStateMonitor?.invalidate()
        deviceStateMonitor = nil
        deviceStateGate.reset()
        let initialState = objectProperty(device, selectorName: "stateString") as? String
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
            let state = objectProperty(device, selectorName: "stateString") as? String
                ?? "Unknown"
            guard let transition = self.deviceStateGate.observe(state: state) else { return }
            self.handleDeviceStateTransition(
                transition,
                device: device,
                deviceIdentifier: deviceIdentifier
            )
        }
        let registeredState = objectProperty(device, selectorName: "stateString") as? String
            ?? "Unknown"
        guard attachedDevice === device,
              currentDeviceIdentifier == deviceIdentifier,
              registeredState.caseInsensitiveCompare("Booted") == .orderedSame else {
            monitor.invalidate()
            throw SimulatorWorkerFailure.deviceNotBooted(
                "Simulator changed to \(registeredState) while state monitoring started."
            )
        }
        deviceStateMonitor = monitor
    }

    private func handleDeviceStateTransition(
        _ transition: SimulatorDeviceStateGate.Transition,
        device: NSObject,
        deviceIdentifier: String
    ) {
        guard attachedDevice === device,
              currentDeviceIdentifier == deviceIdentifier
        else {
            return
        }
        let state: String = switch transition {
        case let .becameUnavailable(state): state
        }

        deviceStateMonitor?.invalidate()
        deviceStateMonitor = nil
        attachedDevice = nil
        hid?.releaseInputs()
        hid = nil
        framebuffer?.stop()
        framebuffer = nil
        accessibility.detach()
        renderContext = nil
        currentDisplay = nil
        currentDeviceIdentifier = nil
        gestureStart = nil
        gestureUsesTwoFingers = false
        pendingKeyUsages.removeAll()
        camera.detachFromUnavailableDevice()
        webInspector.shutdown()

        let failure = SimulatorFailure(
            code: "simulator_device_unavailable",
            message: "Simulator \(deviceIdentifier) changed to \(state).",
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
