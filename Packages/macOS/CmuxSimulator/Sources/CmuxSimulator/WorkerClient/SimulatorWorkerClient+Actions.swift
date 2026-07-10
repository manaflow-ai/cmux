import Foundation

private struct SimulatorCameraConfigurationConfirmation: Sendable {
    let succeeded: Bool
    let targetBundleIdentifier: String?
}

extension SimulatorWorkerClient {
    /// Performs one public Simulator action or routes camera configuration to
    /// the isolated worker.
    public func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        try requireOpen()
        if case let .interactive(interactiveAction) = action {
            let requestID = UUID()
            let succeeded: Bool = try await requestWorkerValue(
                sending: .interactiveAction(requestID: requestID, action: interactiveAction),
                timeout: .seconds(30)
            ) { message in
                guard case let .interactiveAction(responseID, succeeded) = message,
                      responseID == requestID else { return nil }
                return succeeded
            }
            try await sendInteractiveRecovery(for: interactiveAction)
            guard succeeded else {
                throw SimulatorControlError(
                    code: "interactive_action_failed",
                    arguments: [],
                    message: "The isolated worker could not complete the Simulator action."
                )
            }
            return .none
        }
        if let result = try await performWebInspectorAction(action) { return result }
        if let result = try await performAccessibilityAction(action) { return result }
        if case let .setInterface(deviceID, setting) = action,
           setting.requiresSimulatorAccessibilityHelper {
            let requestID = UUID()
            let succeeded: Bool = try await requestWorkerValue(
                sending: .setPrivateInterface(
                    requestID: requestID,
                    deviceID: deviceID,
                    setting: setting
                ),
                timeout: .seconds(120)
            ) { message in
                guard case let .privateInterface(responseID, succeeded) = message,
                      responseID == requestID else { return nil }
                return succeeded
            }
            guard succeeded else {
                throw SimulatorControlError(
                    code: "private_interface_setting_failed",
                    arguments: [],
                    message: "The in-Simulator accessibility helper could not apply the requested setting."
                )
            }
            return .none
        }
        if case let .readInterfaceStatus(deviceID) = action {
            let requestID = UUID()
            let status: SimulatorInterfaceStatus = try await requestWorkerValue(
                sending: .requestPrivateInterfaceStatus(
                    requestID: requestID,
                    deviceID: deviceID
                ),
                timeout: .seconds(120)
            ) { message in
                guard case let .privateInterfaceStatus(responseID, status) = message,
                      responseID == requestID else { return nil }
                return status
            }
            return .interfaceStatus(status)
        }
        if case let .setCameraMirror(mode) = action {
            guard currentCapabilities.contains(.cameraInjection) else {
                throw SimulatorControlError(
                    code: "camera_injection_unavailable",
                    arguments: [],
                    message: "The active Xcode worker did not negotiate an isolated camera adapter."
                )
            }
            let requestID = UUID()
            let succeeded: Bool = try await requestWorkerValue(
                sending: .setCameraMirror(requestID: requestID, mode: mode),
                timeout: .seconds(30)
            ) { message in
                guard case let .cameraMirror(responseID, succeeded) = message,
                      responseID == requestID else { return nil }
                return succeeded
            }
            guard succeeded else {
                throw SimulatorControlError(
                    code: "camera_mirror_failed",
                    arguments: [],
                    message: "The worker could not update camera mirroring."
                )
            }
            lastCameraMirrorMode = mode
            return .none
        }
        if case .readCameraStatus = action {
            let requestID = UUID()
            let status: SimulatorCameraStatus = try await requestWorkerValue(
                sending: .requestCameraStatus(requestID: requestID),
                timeout: .seconds(30)
            ) { message in
                guard case let .cameraStatus(responseID, status) = message,
                      responseID == requestID else { return nil }
                return status
            }
            return .cameraStatus(status)
        }
        if case let .readPrivacy(deviceID, bundleIdentifier) = action {
            guard currentCapabilities.contains(.extendedPermissions) else {
                throw SimulatorControlError(
                    code: "extended_permission_unavailable",
                    arguments: [],
                    message: "The active Xcode worker did not negotiate permission readback."
                )
            }
            let requestID = UUID()
            let snapshot: SimulatorPrivacySnapshot = try await requestWorkerValue(
                sending: .requestPrivacy(
                    requestID: requestID,
                    deviceID: deviceID,
                    bundleIdentifier: bundleIdentifier
                ),
                timeout: .seconds(15)
            ) { message in
                guard case let .privacy(responseID, snapshot) = message,
                      responseID == requestID else { return nil }
                return snapshot
            }
            return .privacy(snapshot)
        }
        if case .reloadReactNative = action {
            let requestID = UUID()
            let succeeded: Bool = try await requestWorkerValue(
                sending: .reloadReactNative(requestID: requestID),
                timeout: .seconds(10)
            ) { message in
                guard case let .reactNativeReload(responseID, succeeded) = message,
                      responseID == requestID else { return nil }
                return succeeded
            }
            guard succeeded else {
                throw SimulatorControlError(
                    code: "react_native_reload_failed",
                    arguments: [],
                    message: "The worker could not reload the foreground React Native application."
                )
            }
            return .none
        }
        if case let .setAccessibilityHighlight(nodeID, frame) = action {
            guard currentCapabilities.contains(.accessibility) else {
                throw SimulatorControlError(
                    code: "accessibility_unavailable",
                    arguments: [],
                    message: "The active Xcode worker did not negotiate accessibility inspection."
                )
            }
            let requestID = UUID()
            let applied: Bool = try await requestWorkerValue(
                sending: .setAccessibilityHighlight(
                    requestID: requestID,
                    nodeID: nodeID,
                    frame: frame
                ),
                timeout: .seconds(10)
            ) { message in
                guard case let .accessibilityHighlight(responseID, applied) = message,
                      responseID == requestID else { return nil }
                return applied
            }
            guard applied else {
                throw SimulatorControlError(
                    code: "accessibility_highlight_failed",
                    arguments: [],
                    message: "The worker could not update the accessibility highlight overlay."
                )
            }
            return .none
        }
        if case let .switchCameraSource(configuration) = action {
            guard currentCapabilities.contains(.cameraInjection) else {
                throw SimulatorControlError(
                    code: "camera_injection_unavailable",
                    arguments: [],
                    message: "The active Xcode worker did not negotiate an isolated camera adapter."
                )
            }
            let requestID = UUID()
            let succeeded: Bool = try await requestWorkerValue(
                sending: .switchCameraSource(
                    requestID: requestID,
                    configuration: configuration
                ),
                timeout: .seconds(120)
            ) { message in
                guard case let .cameraConfiguration(responseID, succeeded, _) = message,
                      responseID == requestID else { return nil }
                return succeeded
            }
            guard succeeded else {
                throw SimulatorControlError(
                    code: "camera_source_switch_failed",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.cameraSourceSwitch",
                        defaultValue: "The isolated worker could not switch the active camera source."
                    )
                )
            }
            cameraReplayConfigurations = Self.cameraReplayConfigurations(
                cameraReplayConfigurations,
                switchingTo: configuration
            )
            return .none
        }
        if case let .configureCamera(configuration) = action {
            if !configuration.isDisabled,
               !currentCapabilities.contains(.cameraInjection) {
                throw SimulatorControlError(
                    code: "camera_injection_unavailable",
                    arguments: [],
                    message: "The active Xcode worker did not negotiate an isolated camera adapter."
                )
            }
            let requestID = UUID()
            let confirmation: SimulatorCameraConfigurationConfirmation = try await requestWorkerValue(
                sending: .configureCamera(requestID: requestID, configuration: configuration),
                timeout: .seconds(120)
            ) { message in
                guard case let .cameraConfiguration(responseID, succeeded, target) = message,
                      responseID == requestID else { return nil }
                return SimulatorCameraConfigurationConfirmation(
                    succeeded: succeeded,
                    targetBundleIdentifier: target
                )
            }
            guard confirmation.succeeded else {
                throw SimulatorControlError(
                    code: "camera_configuration_failed",
                    arguments: [],
                    message: "The isolated worker could not configure the requested camera source and target."
                )
            }
            if configuration.isDisabled {
                cameraReplayConfigurations.removeAll()
                cameraCleanupBundleIdentifiers.removeAll()
                lastCameraMirrorMode = nil
            } else {
                rememberCameraConfiguration(
                    configuration,
                    resolvedTargetBundleIdentifier: confirmation.targetBundleIdentifier
                )
            }
            return .none
        }
        if case let .setPrivacy(deviceID, .reset, .all, bundleIdentifier) = action,
           let bundleIdentifier,
           !bundleIdentifier.isEmpty {
            guard currentCapabilities.contains(.extendedPermissions) else {
                throw SimulatorControlError(
                    code: "extended_permission_unavailable",
                    arguments: [],
                    message: "Reset All needs the active Xcode worker's isolated extended-permissions adapter."
                )
            }
            _ = try await simulatorControl.perform(action)
            try await performPrivatePrivacyMutation(
                deviceID: deviceID,
                action: .reset,
                service: .all,
                bundleIdentifier: bundleIdentifier
            )
            return .none
        }
        if case let .setPrivacy(deviceID, privacyAction, service, bundleIdentifier) = action,
           service.requiresIsolatedMutation {
            guard currentCapabilities.contains(.extendedPermissions) else {
                throw SimulatorControlError(
                    code: "extended_permission_unavailable",
                    arguments: [],
                    message: "The active Xcode worker did not negotiate a safe adapter for \(service.rawValue)."
                )
            }
            guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
                throw SimulatorControlError(
                    code: "missing_bundle_identifier",
                    arguments: [],
                    message: "Private permission changes require an installed application bundle identifier."
                )
            }
            try await performPrivatePrivacyMutation(
                deviceID: deviceID,
                action: privacyAction,
                service: service,
                bundleIdentifier: bundleIdentifier
            )
            return .none
        }
        return try await simulatorControl.perform(action)
    }

    func rememberCameraConfiguration(
        _ configuration: SimulatorCameraConfiguration,
        resolvedTargetBundleIdentifier: String? = nil
    ) {
        let replayConfiguration = Self.cameraReplayConfiguration(
            configuration,
            resolvedTargetBundleIdentifier: resolvedTargetBundleIdentifier
        )
        let target = replayConfiguration.targetBundleIdentifier
        cameraReplayConfigurations.removeAll {
            $0.targetBundleIdentifier == target
        }
        cameraReplayConfigurations.append(replayConfiguration)
        if let target, !target.isEmpty {
            cameraCleanupBundleIdentifiers.insert(target)
        }
    }

    nonisolated static func cameraReplayConfiguration(
        _ configuration: SimulatorCameraConfiguration,
        resolvedTargetBundleIdentifier: String?
    ) -> SimulatorCameraConfiguration {
        guard !configuration.isDisabled,
              let target = resolvedTargetBundleIdentifier,
              !target.isEmpty else { return configuration }
        switch configuration {
        case let .targeted(_, source):
            return .targeted(bundleIdentifier: target, source: source)
        default:
            return .targeted(bundleIdentifier: target, source: configuration)
        }
    }

    nonisolated static func cameraReplayConfigurations(
        _ configurations: [SimulatorCameraConfiguration],
        switchingTo source: SimulatorCameraConfiguration
    ) -> [SimulatorCameraConfiguration] {
        configurations.map {
            guard let target = $0.targetBundleIdentifier else { return source }
            return .targeted(bundleIdentifier: target, source: source)
        }
    }

    func forgetCameraConfiguration(_ configuration: SimulatorCameraConfiguration) {
        let target = configuration.targetBundleIdentifier
        cameraReplayConfigurations.removeAll {
            $0.targetBundleIdentifier == target
        }
    }

    func sendInteractiveRecovery(for action: SimulatorInteractiveAction) async throws {
        switch action {
        case let .gesture(events):
            guard let event = events.last else { return }
            try await sendRequired(.pointer(SimulatorPointerEvent(
                phase: .cancelled,
                primary: event.primary,
                secondary: event.secondary,
                edge: event.edge
            )))
        case let .hardwareButton(button):
            guard let usage = button.recoveryHIDUsage else { return }
            try await sendRequired(.hidButton(SimulatorHIDButtonEvent(
                button: usage,
                phase: .up
            )))
        case .rotate, .coreAnimation, .memoryWarning:
            break
        }
    }

    func performPrivatePrivacyMutation(
        deviceID: String,
        action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService,
        bundleIdentifier: String
    ) async throws {
        let requestID = UUID()
        let succeeded: Bool = try await requestWorkerValue(
            sending: .setPrivatePrivacy(
                requestID: requestID,
                deviceID: deviceID,
                action: action,
                service: service,
                bundleIdentifier: bundleIdentifier
            ),
            timeout: .seconds(15)
        ) { message in
            guard case let .privatePrivacy(responseID, succeeded) = message,
                  responseID == requestID else { return nil }
            return succeeded
        }
        guard succeeded else {
            throw SimulatorControlError(
                code: "private_permission_failed",
                arguments: [],
                message: "The isolated worker could not update \(service.rawValue)."
            )
        }
    }

    func requestWorkerValue<Value: Sendable>(
        sending message: SimulatorWorkerInbound,
        timeout: Duration = .seconds(60),
        matching: @escaping @Sendable (SimulatorWorkerOutbound) -> Value?
    ) async throws -> Value {
        let stream = await subscribe()
        // The correlated response is the liveness proof. Do not put the short
        // interactive ping deadline behind camera compilation or database work.
        try await sendRequired(message, probe: false)
        let requestGeneration = generation
        let sleeper = self.sleeper
        do {
            return try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask {
                    for await event in stream {
                        guard case let .message(outbound) = event else {
                            throw SimulatorControlError(
                                code: "worker_stopped",
                                arguments: [],
                                message: "The Simulator worker stopped before replying."
                            )
                        }
                        if let value = matching(outbound) { return value }
                    }
                    throw SimulatorControlError(
                        code: "worker_stopped",
                        arguments: [],
                        message: "The Simulator worker closed its event stream before replying."
                    )
                }
                group.addTask {
                    try await sleeper.sleep(for: timeout)
                    throw SimulatorControlError(
                        code: "worker_response_timed_out",
                        arguments: [],
                        message: "The Simulator worker did not reply before the bounded deadline."
                    )
                }
                guard let value = try await group.next() else {
                    throw SimulatorControlError(
                        code: "worker_stopped",
                        arguments: [],
                        message: "The Simulator worker did not produce a response."
                    )
                }
                group.cancelAll()
                return value
            }
        } catch let error as SimulatorControlError
            where error.code == "worker_response_timed_out" {
            correlatedOperationDeadlineExpired(generation: requestGeneration, failure: error)
            throw error
        }
    }
}
