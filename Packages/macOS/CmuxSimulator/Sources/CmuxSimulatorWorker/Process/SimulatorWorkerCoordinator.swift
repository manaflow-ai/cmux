import CmuxSimulator
import Foundation
import os

nonisolated let coordinatorLogger = Logger(
    subsystem: "com.cmux.simulator.worker",
    category: "Coordinator"
)

@MainActor
final class SimulatorWorkerCoordinator {
    let channel: SimulatorLengthPrefixedMessageChannel
    let encoder = JSONEncoder()
    let frameworkLoader = SimulatorFrameworkLoader()
    let accessibility = SimulatorAccessibilityBridge()
    let subprocessRunner: SimulatorSubprocessRunner
    let camera: SimulatorCameraAdapter
    let interfaceSettings: SimulatorAXSettingsAdapter
    let privacy: SimulatorPrivatePrivacyAdapter
    let webInspector: SimulatorWebInspectorService

    var resolver: SimulatorDeviceResolver?
    var renderContext: SimulatorRemoteRenderContext?
    var framebuffer: SimulatorFramebuffer?
    var hid: SimulatorHIDTransport?
    var currentDisplay: SimulatorDisplayMetadata?
    var currentDeviceIdentifier: String?
    var attachedDevice: NSObject?
    var deviceStateMonitor: SimulatorDeviceStateMonitor?
    var deviceStateGate = SimulatorDeviceStateGate()
    var frameworksLoaded = false
    var gestureStart: SimulatorPoint?
    var gestureUsesTwoFingers = false
    var pendingKeyUsages: Set<UInt32> = []

    init(
        channel: SimulatorLengthPrefixedMessageChannel,
        subprocessRunner: SimulatorSubprocessRunner = SimulatorSubprocessRunner()
    ) {
        self.channel = channel
        self.subprocessRunner = subprocessRunner
        camera = SimulatorCameraAdapter(subprocessRunner: subprocessRunner)
        interfaceSettings = SimulatorAXSettingsAdapter(subprocessRunner: subprocessRunner)
        privacy = SimulatorPrivatePrivacyAdapter(subprocessRunner: subprocessRunner)
        webInspector = SimulatorWebInspectorService(subprocessRunner: subprocessRunner)
        webInspector.eventHandler = { [weak self] event in
            self?.receiveWebInspectorEvent(event)
        }
    }

    /// Applies one command after every preceding command in the pipe.
    /// - Returns: `false` when the worker should exit cleanly.
    func handle(_ message: SimulatorWorkerInbound) async -> Bool {
        switch message {
        case let .ping(sequence):
            send(.ack(sequence))
        case let .attach(udid, geometry):
            await attach(udid: udid, geometry: geometry)
        case let .resize(geometry):
            framebuffer?.resize(geometry)
        case let .pointer(event):
            guard hid?.send(event) == true else {
                if event.phase != .moved {
                    reportUnavailable(action: "pointer", detail: "Touch injection is unavailable.")
                }
                break
            }
            switch event.phase {
            case .began:
                gestureStart = event.primary
                gestureUsesTwoFingers = event.secondary != nil
            case .moved:
                break
            case .ended, .cancelled:
                let start = gestureStart ?? event.primary
                emitAction(
                    "pointer",
                    summary: Self.gestureSummary(
                        start: start,
                        end: event.primary,
                        twoFinger: gestureUsesTwoFingers || event.secondary != nil,
                        cancelled: event.phase == .cancelled
                    ),
                    succeeded: true
                )
                gestureStart = nil
                gestureUsesTwoFingers = false
            }
        case let .key(event):
            guard hid?.send(event) == true else {
                reportUnavailable(action: "key", detail: "Keyboard injection is unavailable.")
                break
            }
            switch event.phase {
            case .down:
                pendingKeyUsages.insert(event.usage)
            case .up:
                if pendingKeyUsages.remove(event.usage) != nil {
                    emitAction(
                        "key",
                        summary: SimulatorKeyboardEventLog.summary(for: event.usage),
                        succeeded: true
                    )
                }
            }
        case let .typeText(requestIdentifier, sequence):
            let succeeded = await hid?.sendTextSequence(sequence) == true
            if !succeeded {
                pendingKeyUsages.removeAll()
            }
            if !succeeded {
                reportUnavailable(
                    action: "type_text",
                    detail: "Keyboard injection failed before the text sequence finished transmission."
                )
            }
            emitAction(
                "type_text",
                summary: "characters:\(sequence.characterCount)",
                succeeded: succeeded
            )
            send(.textInput(requestID: requestIdentifier, succeeded: succeeded))
        case let .interactiveAction(requestIdentifier, action):
            let succeeded = await performInteractiveAction(action)
            send(.interactiveAction(requestID: requestIdentifier, succeeded: succeeded))
        case let .button(button):
            let succeeded: Bool
            if button == .home, let currentDeviceIdentifier {
                succeeded = await foregroundSpringBoard(deviceIdentifier: currentDeviceIdentifier)
            } else {
                succeeded = await hid?.press(button) == true
            }
            guard succeeded else {
                reportUnavailable(
                    action: "button",
                    detail: "The selected hardware-button transport is unavailable."
                )
                break
            }
            emitAction("button", summary: button.rawValue, succeeded: true)
        case let .hidButton(event):
            guard hid?.send(event) == true else {
                reportUnavailable(
                    action: "button",
                    detail: "The selected raw HID button transport is unavailable."
                )
                break
            }
            emitAction(
                "button",
                summary: String(
                    format: "0x%X:0x%X:%@",
                    event.button.page,
                    event.button.usage,
                    event.phase.rawValue
                ),
                succeeded: true
            )
        case let .rotate(orientation):
            guard hid?.rotate(orientation) == true else {
                reportUnavailable(action: "rotate", detail: "Device rotation is unavailable.")
                break
            }
            framebuffer?.setOrientation(orientation)
            emitAction("rotate", summary: orientation.rawValue, succeeded: true)
        case let .digitalCrown(delta):
            guard hid?.sendDigitalCrown(delta) == true else {
                reportUnavailable(
                    action: "digital_crown",
                    detail: "Digital Crown injection is unavailable."
                )
                break
            }
            emitAction("digital_crown", summary: String(delta), succeeded: true)
        case .toggleSoftwareKeyboard:
            guard hid?.toggleSoftwareKeyboard() == true else {
                reportUnavailable(
                    action: "software_keyboard",
                    detail: "Software-keyboard injection is unavailable."
                )
                break
            }
            emitAction("software_keyboard", summary: "toggle", succeeded: true)
        case .memoryWarning:
            guard hid?.simulateMemoryWarning() == true else {
                reportUnavailable(action: "memory_warning", detail: "Memory warnings are unavailable.")
                break
            }
            emitAction("memory_warning", summary: "simulate", succeeded: true)
        case let .coreAnimationDiagnostic(diagnostic, enabled):
            guard hid?.setCoreAnimationDiagnostic(diagnostic, enabled: enabled) == true else {
                reportUnavailable(
                    action: "core_animation_diagnostic",
                    detail: "Core Animation diagnostics are unavailable."
                )
                break
            }
            emitAction(
                "core_animation_diagnostic",
                summary: "\(diagnostic.rawValue):\(enabled)",
                succeeded: true
            )
        case let .configureCamera(requestIdentifier, configuration):
            var succeeded = false
            var resolvedTargetBundleIdentifier: String?
            do {
                let inferredApplication: SimulatorApplicationInfo?
                if configuration.targetBundleIdentifier == nil {
                    inferredApplication = try accessibility.foregroundApplication()
                } else {
                    inferredApplication = nil
                }
                let application = try await camera.configure(
                    configuration,
                    inferredApplication: inferredApplication
                )
                succeeded = true
                let target = application?.bundleIdentifier
                    ?? configuration.targetBundleIdentifier
                    ?? inferredApplication?.bundleIdentifier
                    ?? "disabled"
                resolvedTargetBundleIdentifier = target == "disabled" ? nil : target
                let pid = application?.processIdentifier.map(String.init) ?? "unknown"
                emitAction("camera", summary: "\(target):\(pid)", succeeded: true)
            } catch {
                report(error)
                emitAction("camera", summary: error.localizedDescription, succeeded: false)
            }
            send(.cameraConfiguration(
                requestID: requestIdentifier,
                succeeded: succeeded,
                targetBundleIdentifier: resolvedTargetBundleIdentifier
            ))
        case let .switchCameraSource(requestIdentifier, configuration):
            var succeeded = false
            do {
                try await camera.switchSource(configuration)
                succeeded = true
                emitAction("camera_source", summary: "switched", succeeded: true)
            } catch {
                report(error)
                emitAction("camera_source", summary: error.localizedDescription, succeeded: false)
            }
            send(.cameraConfiguration(
                requestID: requestIdentifier,
                succeeded: succeeded,
                targetBundleIdentifier: nil
            ))
        case let .setCameraMirror(requestIdentifier, mode):
            let succeeded = camera.setMirrorMode(mode)
            send(.cameraMirror(requestID: requestIdentifier, succeeded: succeeded))
            emitAction("camera_mirror", summary: mode.rawValue, succeeded: succeeded)
        case let .requestCameraStatus(requestIdentifier):
            let status = camera.status()
            send(.cameraStatus(requestID: requestIdentifier, status))
        case let .setPrivateInterface(requestIdentifier, deviceID, setting):
            var succeeded = false
            do {
                guard currentDeviceIdentifier == deviceID else {
                    throw SimulatorWorkerFailure.deviceNotFound(
                        "The interface-settings target does not match the attached Simulator."
                    )
                }
                try await interfaceSettings.set(
                    deviceIdentifier: deviceID,
                    setting: setting
                )
                succeeded = true
                emitAction(
                    "private_interface",
                    summary: String(describing: setting),
                    succeeded: true
                )
            } catch {
                report(error)
                emitAction(
                    "private_interface",
                    summary: error.localizedDescription,
                    succeeded: false
                )
            }
            send(.privateInterface(requestID: requestIdentifier, succeeded: succeeded))
        case let .requestPrivateInterfaceStatus(requestIdentifier, deviceID):
            do {
                guard currentDeviceIdentifier == deviceID else {
                    throw SimulatorWorkerFailure.deviceNotFound(
                        "The interface-status target does not match the attached Simulator."
                    )
                }
                let status = try await interfaceSettings.status(deviceIdentifier: deviceID)
                send(.privateInterfaceStatus(requestID: requestIdentifier, status))
                emitAction("private_interface_status", summary: deviceID, succeeded: true)
            } catch {
                report(error)
                emitAction(
                    "private_interface_status",
                    summary: error.localizedDescription,
                    succeeded: false
                )
            }
        case let .setPrivatePrivacy(
            requestIdentifier,
            deviceID,
            action,
            service,
            bundleIdentifier
        ):
            var succeeded = false
            do {
                guard currentDeviceIdentifier == deviceID else {
                    throw SimulatorWorkerFailure.deviceNotFound(
                        "The permission target does not match the attached Simulator."
                    )
                }
                try await privacy.set(
                    deviceIdentifier: deviceID,
                    action: action,
                    service: service,
                    bundleIdentifier: bundleIdentifier
                )
                succeeded = true
                emitAction(
                    "privacy",
                    summary: "\(action.rawValue):\(service.rawValue):\(bundleIdentifier)",
                    succeeded: true
                )
            } catch {
                report(error)
                emitAction("privacy", summary: error.localizedDescription, succeeded: false)
            }
            send(.privatePrivacy(requestID: requestIdentifier, succeeded: succeeded))
        case let .requestPrivacy(requestIdentifier, deviceID, bundleIdentifier):
            let snapshot = await privacy.snapshot(
                deviceIdentifier: deviceID,
                bundleIdentifier: bundleIdentifier
            )
            send(.privacy(requestID: requestIdentifier, snapshot))
            emitAction(
                "privacy_status",
                summary: bundleIdentifier ?? "runtime",
                succeeded: true
            )
        case let .reloadReactNative(requestIdentifier):
            let succeeded = hid?.reloadReactNative() == true
            if !succeeded {
                report(
                    SimulatorWorkerFailure.inputUnavailable(
                        "The keyboard transport could not deliver React Native's Command-R reload."
                    )
                )
            }
            send(.reactNativeReload(requestID: requestIdentifier, succeeded: succeeded))
            emitAction("react_native_reload", summary: "command-r", succeeded: succeeded)
        case let .setAccessibilityHighlight(requestIdentifier, nodeIdentifier, frame):
            var targetFrame = frame
            let isClear = nodeIdentifier == nil && frame == nil
            if !isClear,
               let currentDisplay,
               let snapshot = try? accessibility.accessibilitySnapshot(display: currentDisplay) {
                framebuffer?.setAccessibilityCoordinateSpace(
                    Self.accessibilityCoordinateSpace(nodes: snapshot.roots)
                )
                if targetFrame == nil, let nodeIdentifier {
                    targetFrame = Self.accessibilityFrame(
                        nodeIdentifier: nodeIdentifier,
                        nodes: snapshot.roots
                    )
                }
            }
            let applied: Bool
            if isClear {
                applied = framebuffer?.setAccessibilityHighlight(nil) == true
            } else if let targetFrame {
                applied = framebuffer?.setAccessibilityHighlight(targetFrame) == true
            } else {
                applied = false
            }
            if !applied {
                reportUnavailable(
                    action: "accessibility_highlight",
                    detail: "The requested accessibility node frame is unavailable."
                )
            } else {
                emitAction(
                    "accessibility_highlight",
                    summary: isClear ? "clear" : nodeIdentifier ?? "frame",
                    succeeded: true
                )
            }
            send(.accessibilityHighlight(requestID: requestIdentifier, applied: applied))
        case let .requestAccessibility(requestIdentifier):
            guard let currentDisplay else {
                let failure = SimulatorFailure(
                    code: "accessibility_unavailable",
                    message: "Accessibility requires a live framebuffer.",
                    isRecoverable: true
                )
                send(.requestFailure(requestID: requestIdentifier, failure))
                break
            }
            do {
                let snapshot = try accessibility.accessibilitySnapshot(display: currentDisplay)
                framebuffer?.setAccessibilityCoordinateSpace(
                    Self.accessibilityCoordinateSpace(nodes: snapshot.roots)
                )
                send(.accessibility(requestID: requestIdentifier, snapshot))
            } catch {
                report(error, requestID: requestIdentifier)
            }
        case let .requestForegroundApplication(requestIdentifier):
            do {
                let application = try accessibility.foregroundApplication()
                send(.foregroundApplication(requestID: requestIdentifier, application))
            } catch {
                report(error, requestID: requestIdentifier)
            }
        case let .requestWebInspectorTargets(requestIdentifier, deviceIdentifier):
            await requestWebInspectorTargets(
                requestIdentifier: requestIdentifier,
                deviceIdentifier: deviceIdentifier
            )
        case let .attachWebInspector(requestIdentifier, targetIdentifier):
            await attachWebInspector(
                requestIdentifier: requestIdentifier,
                targetIdentifier: targetIdentifier
            )
        case let .releaseWebInspector(requestIdentifier):
            releaseWebInspector(requestIdentifier: requestIdentifier)
        case let .setWebInspectorHighlight(requestIdentifier, enabled):
            await setWebInspectorHighlight(
                requestIdentifier: requestIdentifier,
                enabled: enabled
            )
        case let .sendWebInspectorMessage(requestIdentifier, json):
            sendWebInspectorMessage(requestIdentifier: requestIdentifier, json: json)
        case .releaseInputs:
            hid?.releaseInputs()
            pendingKeyUsages.removeAll()
        case .terminateRenderer:
            #if DEBUG
            _exit(86)
            #else
            report(
                SimulatorWorkerFailure.privateAPIUnavailable(
                    "Intentional worker termination is unavailable in release builds."
                )
            )
            #endif
        case .shutdown:
            await shutdown()
            return false
        }
        return true
    }

}
