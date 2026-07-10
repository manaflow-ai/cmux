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
    let accessibilityExecutor: any SimulatorAccessibilityExecuting
    let subprocessRunner: SimulatorSubprocessRunner
    let camera: SimulatorCameraAdapter
    let interfaceSettings: SimulatorAXSettingsAdapter
    let privacy: SimulatorPrivatePrivacyAdapter
    let webInspector: SimulatorWebInspectorService
    let toolOperationSleeper: any SimulatorHIDSleeping
    let toolOperationContainment: SimulatorToolOperationContainment
    let mutationGate: SimulatorMutationGate

    var resolver: SimulatorDeviceResolver?
    var renderContext: SimulatorRemoteRenderContext?
    var framebuffer: SimulatorFramebuffer?
    var hid: SimulatorHIDTransport?
    var scrollWheel: SimulatorScrollWheelController?
    var currentDisplay: SimulatorDisplayMetadata?
    var currentDeviceIdentifier: String?
    var attachedDevice: NSObject?
    var deviceStateMonitor: SimulatorDeviceStateMonitor?
    var deviceStateGate = SimulatorDeviceStateGate()
    var frameworksLoaded = false
    var gestureStart: SimulatorPoint?
    var gestureUsesTwoFingers = false
    var pendingKeyUsages: Set<UInt32> = []
    var foregroundApplicationTask: Task<Void, Never>?
    var foregroundApplicationGeneration: UUID?
    var foregroundApplicationRequestIdentifiers: [UUID] = []
    var accessibilitySnapshotTask: Task<Void, Never>?
    var accessibilitySnapshotGeneration: UUID?
    var accessibilitySnapshotRequestIdentifiers: [UUID] = []
    var accessibilitySnapshotDeviceIdentifier: String?
    var accessibilitySnapshotDisplay: SimulatorDisplayMetadata?
    var cachedAccessibilitySnapshot: SimulatorAccessibilitySnapshot?
    var toolOperationQueues: [SimulatorToolOperationLane: [SimulatorQueuedToolOperation]] = [:]
    var toolOperationTasks: [SimulatorToolOperationLane: Task<Void, Never>] = [:]
    var toolOperationDeadlineTasks: [SimulatorToolOperationLane: Task<Void, Never>] = [:]
    var toolOperationCancellationGraceTasks: [SimulatorToolOperationLane: Task<Void, Never>] = [:]
    var toolOperationGenerations: [SimulatorToolOperationLane: UUID] = [:]
    var toolOperationCurrentRequestIdentifiers: [SimulatorToolOperationLane: UUID] = [:]
    var cancelingToolOperationLanes: Set<SimulatorToolOperationLane> = []
    var timedOutToolOperationGenerations: Set<UUID> = []
    var pendingCameraTargetAcknowledgements: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(
        channel: SimulatorLengthPrefixedMessageChannel,
        subprocessRunner: SimulatorSubprocessRunner = SimulatorSubprocessRunner(),
        accessibilityExecutor: (any SimulatorAccessibilityExecuting)? = nil,
        toolOperationSleeper: any SimulatorHIDSleeping = ContinuousSimulatorHIDSleeper(),
        toolOperationContainment: SimulatorToolOperationContainment = SimulatorToolOperationContainment()
    ) {
        self.channel = channel
        self.subprocessRunner = subprocessRunner
        self.accessibilityExecutor = accessibilityExecutor ?? SimulatorAccessibilityExecutor()
        self.toolOperationSleeper = toolOperationSleeper
        self.toolOperationContainment = toolOperationContainment
        let mutationGate = SimulatorMutationGate()
        self.mutationGate = mutationGate
        let inspector = SimulatorWebInspectorService(
            subprocessRunner: subprocessRunner,
            mutationGate: mutationGate
        )
        webInspector = inspector
        camera = SimulatorCameraAdapter(
            subprocessRunner: subprocessRunner,
            mutationGate: mutationGate,
            applicationMutationWillCommit: { [weak inspector] bundleIdentifier in
                inspector?.releaseSessionWithoutMutationGate(ifOwnedBy: bundleIdentifier)
            }
        )
        interfaceSettings = SimulatorAXSettingsAdapter(subprocessRunner: subprocessRunner)
        privacy = SimulatorPrivatePrivacyAdapter(
            subprocessRunner: subprocessRunner,
            mutationGate: mutationGate
        )
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
            if event.phase == .began { scrollWheel?.cancel() }
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
        case let .keySequence(events):
            let succeeded = await hid?.sendPacedKeySequence(events) == true
            if !succeeded {
                reportUnavailable(
                    action: "key_sequence",
                    detail: "The paced keyboard chord could not be delivered."
                )
            }
            emitAction("key_sequence", summary: "events:\(events.count)", succeeded: succeeded)
        case let .scrollWheel(event):
            guard let scrollWheel else {
                send(.scrollWheelEnded(eventID: event.id))
                reportUnavailable(action: "scroll", detail: "Wheel scrolling is unavailable.")
                break
            }
            let succeeded = await scrollWheel.send(event)
            if !succeeded {
                reportUnavailable(action: "scroll", detail: "Wheel scrolling is unavailable.")
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
            let succeeded = await hid?.press(button) == true
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
            enqueueToolOperation(
                lane: .camera,
                requestIdentifier: requestIdentifier,
                timeout: .seconds(110)
            ) { coordinator, generation in
                await coordinator.configureCamera(
                    requestIdentifier: requestIdentifier,
                    configuration: configuration,
                    operationGeneration: generation
                )
            }
        case let .acknowledgeCameraTarget(requestIdentifier):
            pendingCameraTargetAcknowledgements
                .removeValue(forKey: requestIdentifier)?
                .resume()
        case let .switchCameraSource(requestIdentifier, configuration):
            enqueueToolOperation(
                lane: .camera,
                requestIdentifier: requestIdentifier,
                timeout: .seconds(110)
            ) { coordinator, generation in
                await coordinator.switchCameraSource(
                    requestIdentifier: requestIdentifier,
                    configuration: configuration,
                    operationGeneration: generation
                )
            }
        case let .setCameraMirror(requestIdentifier, mode):
            let succeeded = camera.setMirrorMode(mode)
            send(.cameraMirror(requestID: requestIdentifier, succeeded: succeeded))
            emitAction("camera_mirror", summary: mode.rawValue, succeeded: succeeded)
        case let .requestCameraStatus(requestIdentifier):
            let status = camera.status()
            send(.cameraStatus(requestID: requestIdentifier, status))
        case let .prepareApplicationMutation(requestIdentifier, bundleIdentifier):
            enqueueToolOperation(
                lane: .camera,
                requestIdentifier: requestIdentifier,
                timeout: .seconds(30)
            ) { coordinator, generation in
                await coordinator.prepareApplicationMutation(
                    requestIdentifier: requestIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    operationGeneration: generation
                )
            }
        case let .setPrivateInterface(requestIdentifier, deviceID, setting):
            enqueueToolOperation(
                lane: .maintenance,
                requestIdentifier: requestIdentifier,
                timeout: .seconds(110)
            ) { coordinator, generation in
                await coordinator.setPrivateInterface(
                    requestIdentifier: requestIdentifier,
                    deviceIdentifier: deviceID,
                    setting: setting,
                    operationGeneration: generation
                )
            }
        case let .requestPrivateInterfaceStatus(requestIdentifier, deviceID):
            enqueueToolOperation(
                lane: .maintenance,
                requestIdentifier: requestIdentifier,
                timeout: .seconds(110)
            ) { coordinator, generation in
                await coordinator.requestPrivateInterfaceStatus(
                    requestIdentifier: requestIdentifier,
                    deviceIdentifier: deviceID,
                    operationGeneration: generation
                )
            }
        case let .setPrivatePrivacy(
            requestIdentifier,
            deviceID,
            action,
            service,
            bundleIdentifier
        ):
            enqueueToolOperation(
                lane: .maintenance,
                requestIdentifier: requestIdentifier,
                timeout: service == .all ? .seconds(110) : .seconds(25)
            ) { coordinator, generation in
                await coordinator.setPrivatePrivacy(
                    requestIdentifier: requestIdentifier,
                    deviceIdentifier: deviceID,
                    action: action,
                    service: service,
                    bundleIdentifier: bundleIdentifier,
                    operationGeneration: generation
                )
            }
        case let .requestPrivacy(requestIdentifier, deviceID, bundleIdentifier):
            enqueueToolOperation(
                lane: .maintenance,
                requestIdentifier: requestIdentifier,
                timeout: .seconds(25)
            ) { coordinator, generation in
                await coordinator.requestPrivacy(
                    requestIdentifier: requestIdentifier,
                    deviceIdentifier: deviceID,
                    bundleIdentifier: bundleIdentifier,
                    operationGeneration: generation
                )
            }
        case let .reloadReactNative(requestIdentifier):
            let succeeded = await hid?.reloadReactNative() == true
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
               let snapshot = cachedAccessibilitySnapshot,
               snapshot.display == currentDisplay {
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
            requestAccessibility(requestIdentifier: requestIdentifier)
        case let .requestForegroundApplication(requestIdentifier):
            requestForegroundApplication(requestIdentifier: requestIdentifier)
        case let .requestWebInspectorTargets(requestIdentifier, deviceIdentifier):
            enqueueToolOperation(
                lane: .webInspector,
                requestIdentifier: requestIdentifier,
                timeout: .seconds(8)
            ) { coordinator, generation in
                await coordinator.requestWebInspectorTargets(
                    requestIdentifier: requestIdentifier,
                    deviceIdentifier: deviceIdentifier,
                    operationGeneration: generation
                )
            }
        case let .attachWebInspector(requestIdentifier, targetIdentifier):
            enqueueToolOperation(
                lane: .webInspector,
                requestIdentifier: requestIdentifier,
                timeout: .seconds(8)
            ) { coordinator, generation in
                await coordinator.attachWebInspector(
                    requestIdentifier: requestIdentifier,
                    targetIdentifier: targetIdentifier,
                    operationGeneration: generation
                )
            }
        case let .releaseWebInspector(requestIdentifier):
            enqueueToolOperation(
                lane: .webInspector,
                requestIdentifier: requestIdentifier,
                timeout: .seconds(4)
            ) { coordinator, generation in
                await coordinator.releaseWebInspector(
                    requestIdentifier: requestIdentifier,
                    operationGeneration: generation
                )
            }
        case let .setWebInspectorHighlight(requestIdentifier, enabled):
            enqueueToolOperation(
                lane: .webInspector,
                requestIdentifier: requestIdentifier,
                timeout: .seconds(8)
            ) { coordinator, generation in
                await coordinator.setWebInspectorHighlight(
                    requestIdentifier: requestIdentifier,
                    enabled: enabled,
                    operationGeneration: generation
                )
            }
        case let .sendWebInspectorMessage(requestIdentifier, json):
            enqueueToolOperation(
                lane: .webInspector,
                requestIdentifier: requestIdentifier,
                timeout: .seconds(4)
            ) { coordinator, generation in
                await coordinator.sendWebInspectorMessage(
                    requestIdentifier: requestIdentifier,
                    json: json,
                    operationGeneration: generation
                )
            }
        case .releaseInputs:
            scrollWheel?.cancel()
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
            prepareForProcessExit()
            return false
        }
        return true
    }

}
