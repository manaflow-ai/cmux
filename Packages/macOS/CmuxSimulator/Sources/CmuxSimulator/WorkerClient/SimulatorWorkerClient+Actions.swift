import Foundation

private struct SimulatorCameraConfigurationConfirmation: Sendable {
    let succeeded: Bool
    let targetBundleIdentifier: String?
}

extension SimulatorWorkerClient {
    public func synchronizeOrientation(
        _ orientation: SimulatorOrientation
    ) async throws -> SimulatorDisplayMetadata? {
        _ = try await perform(.interactive(.rotate(orientation)))
        guard currentDisplayMetadata?.orientation == orientation else {
            throw SimulatorControlError(
                code: "orientation_synchronization_failed",
                arguments: [],
                message: String(
                    localized: "simulator.failure.orientationSynchronization",
                    defaultValue: "The Simulator did not confirm its requested orientation."
                )
            )
        }
        return currentDisplayMetadata
    }

    /// Performs one public Simulator action or routes camera configuration to
    /// the isolated worker.
    public func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        try requireOpen()
        if let result = try await performApplicationLifecycleAction(action) { return result }
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
            try? await sendInteractiveRecovery(for: interactiveAction)
            guard succeeded else {
                throw SimulatorControlError(
                    code: "interactive_action_failed",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.interactiveActionFailed",
                        defaultValue: "The isolated worker could not complete the Simulator action."
                    )
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
                timeout: .seconds(120),
                timeoutRecovery: .restartWorker
            ) { message in
                guard case let .privateInterface(responseID, succeeded) = message,
                      responseID == requestID else { return nil }
                return succeeded
            }
            guard succeeded else {
                throw SimulatorControlError(
                    code: "private_interface_setting_failed",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.privateInterfaceSettingFailed",
                        defaultValue: "The in-Simulator accessibility helper could not apply the requested setting."
                    )
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
                timeout: .seconds(120),
                timeoutRecovery: .restartWorker
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
                    message: String(
                        localized: "simulator.failure.cameraAdapterCapability",
                        defaultValue: "The active Xcode worker did not negotiate an isolated camera adapter."
                    )
                )
            }
            let requestID = UUID()
            let succeeded: Bool = try await requestWorkerValue(
                sending: .setCameraMirror(requestID: requestID, mode: mode),
                timeout: .seconds(30),
                timeoutRecovery: .restartWorker
            ) { message in
                guard case let .cameraMirror(responseID, succeeded) = message,
                      responseID == requestID else { return nil }
                return succeeded
            }
            guard succeeded else {
                throw SimulatorControlError(
                    code: "camera_mirror_failed",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.cameraMirrorFailed",
                        defaultValue: "The worker could not update camera mirroring."
                    )
                )
            }
            return .none
        }
        if case .readCameraStatus = action {
            let requestID = UUID()
            let status: SimulatorCameraStatus = try await requestWorkerValue(
                sending: .requestCameraStatus(requestID: requestID),
                timeout: .seconds(30),
                timeoutRecovery: .restartWorker
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
                    message: String(
                        localized: "simulator.failure.permissionReadbackCapability",
                        defaultValue: "The active Xcode worker did not negotiate permission readback."
                    )
                )
            }
            let requestID = UUID()
            let snapshot: SimulatorPrivacySnapshot = try await requestWorkerValue(
                sending: .requestPrivacy(
                    requestID: requestID,
                    deviceID: deviceID,
                    bundleIdentifier: bundleIdentifier
                ),
                timeout: .seconds(30),
                timeoutRecovery: .preserveWorker
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
                timeout: .seconds(10),
                timeoutRecovery: .preserveWorker
            ) { message in
                guard case let .reactNativeReload(responseID, succeeded) = message,
                      responseID == requestID else { return nil }
                return succeeded
            }
            guard succeeded else {
                throw SimulatorControlError(
                    code: "react_native_reload_failed",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.reactNativeReloadFailed",
                        defaultValue: "The worker could not reload the foreground React Native application."
                    )
                )
            }
            return .none
        }
        if case let .setAccessibilityHighlight(nodeID, frame) = action {
            guard currentCapabilities.contains(.accessibility) else {
                throw SimulatorControlError(
                    code: "accessibility_unavailable",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.accessibilityCapability",
                        defaultValue: "The active Xcode worker did not negotiate accessibility inspection."
                    )
                )
            }
            let requestID = UUID()
            let applied: Bool = try await requestWorkerValue(
                sending: .setAccessibilityHighlight(
                    requestID: requestID,
                    nodeID: nodeID,
                    frame: frame
                ),
                timeout: .seconds(10),
                timeoutRecovery: .restartWorker
            ) { message in
                guard case let .accessibilityHighlight(responseID, applied) = message,
                      responseID == requestID else { return nil }
                return applied
            }
            guard applied else {
                throw SimulatorControlError(
                    code: "accessibility_highlight_failed",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.accessibilityHighlightFailed",
                        defaultValue: "The worker could not update the accessibility highlight overlay."
                    )
                )
            }
            return .none
        }
        if case let .switchCameraSource(configuration) = action {
            guard currentCapabilities.contains(.cameraInjection) else {
                throw SimulatorControlError(
                    code: "camera_injection_unavailable",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.cameraAdapterCapability",
                        defaultValue: "The active Xcode worker did not negotiate an isolated camera adapter."
                    )
                )
            }
            let requestID = UUID()
            let succeeded: Bool = try await requestWorkerValue(
                sending: .switchCameraSource(
                    requestID: requestID,
                    configuration: configuration
                ),
                timeout: .seconds(120),
                timeoutRecovery: .restartWorker
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
            return .none
        }
        if case let .configureCamera(configuration) = action {
            if !configuration.isDisabled,
               !currentCapabilities.contains(.cameraInjection) {
                throw SimulatorControlError(
                    code: "camera_injection_unavailable",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.cameraAdapterCapability",
                        defaultValue: "The active Xcode worker did not negotiate an isolated camera adapter."
                    )
                )
            }
            let requestID = UUID()
            let confirmation: SimulatorCameraConfigurationConfirmation = try await requestWorkerValue(
                sending: .configureCamera(requestID: requestID, configuration: configuration),
                timeout: .seconds(120),
                timeoutRecovery: .restartWorker
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
                    message: String(
                        localized: "simulator.failure.cameraConfigurationFailed",
                        defaultValue: "The isolated worker could not configure the requested camera source and target."
                    )
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
                    message: String(
                        localized: "simulator.failure.permissionResetAllCapability",
                        defaultValue: "Reset All needs the active Xcode worker's isolated extended-permissions adapter."
                    )
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
                    message: String(
                        localized: "simulator.failure.permissionMutationCapability",
                        defaultValue: "The active Xcode worker did not negotiate a safe adapter for \(service.rawValue)."
                    )
                )
            }
            guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
                throw SimulatorControlError(
                    code: "missing_bundle_identifier",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.permissionBundleIdentifierRequired",
                        defaultValue: "Private permission changes require an installed application bundle identifier."
                    )
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
        let replayConfiguration = simulatorCameraReplayConfiguration(
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
            timeout: service == .all ? .seconds(120) : .seconds(30),
            timeoutRecovery: .restartWorker
        ) { message in
            guard case let .privatePrivacy(responseID, succeeded) = message,
                  responseID == requestID else { return nil }
            return succeeded
        }
        guard succeeded else {
            throw SimulatorControlError(
                code: "private_permission_failed",
                arguments: [],
                message: String(
                    localized: "simulator.failure.privatePermissionFailed",
                    defaultValue: "The isolated worker could not update \(service.rawValue)."
                )
            )
        }
    }

}

func simulatorCameraReplayConfiguration(
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

func simulatorCameraReplayConfigurations(
    _ configurations: [SimulatorCameraConfiguration],
    switchingTo source: SimulatorCameraConfiguration
) -> [SimulatorCameraConfiguration] {
    configurations.map {
        guard let target = $0.targetBundleIdentifier else { return source }
        return .targeted(bundleIdentifier: target, source: source)
    }
}
