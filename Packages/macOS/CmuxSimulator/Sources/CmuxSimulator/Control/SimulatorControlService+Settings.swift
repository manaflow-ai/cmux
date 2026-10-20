import Foundation

extension SimulatorControlService {
    /// Changes one application privacy service through `simctl privacy`.
    public func setPrivacy(
        deviceID: String,
        action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService,
        bundleIdentifier: String?
    ) async throws {
        guard let simctlService = simctlPrivacyService(for: service) else {
            throw SimulatorControlError(
                code: "unsupported_private_permission",
                arguments: ["simctl", "privacy", deviceID, action.rawValue, service.rawValue],
                message: String(
                    localized: "simulator.control.privacyServiceUnavailable",
                    defaultValue: "The active Xcode does not expose \(service.rawValue) through simctl; cmux will not mutate private TCC or BulletinBoard stores in the host process."
                )
            )
        }
        if action != .reset, bundleIdentifier == nil {
            throw SimulatorControlError(
                code: "missing_bundle_identifier",
                arguments: ["simctl", "privacy", deviceID, action.rawValue, simctlService],
                message: String(
                    localized: "simulator.control.privacyBundleIdentifierRequired",
                    defaultValue: "Granting or revoking privacy access requires a bundle identifier."
                )
            )
        }
        var arguments = ["simctl", "privacy", deviceID, action.rawValue, simctlService]
        if let bundleIdentifier { arguments.append(bundleIdentifier) }
        try await mutationGate.withLocks([.tcc(deviceIdentifier: deviceID)]) {
            _ = try await output(arguments: arguments)
        }
    }

    /// Merges one or more values into the simulated status bar.
    public func overrideStatusBar(deviceID: String, values: SimulatorStatusBarOverride) async throws {
        var arguments = ["simctl", "status_bar", deviceID, "override"]
        if let time = values.time { arguments += ["--time", time] }
        if let dataNetwork = values.dataNetwork { arguments += ["--dataNetwork", dataNetwork.rawValue] }
        if let wifiMode = values.wifiMode { arguments += ["--wifiMode", wifiMode.rawValue] }
        if let wifiBars = values.wifiBars {
            try validate(wifiBars, range: 0...3, name: "Wi-Fi bars", arguments: arguments)
            arguments += ["--wifiBars", String(wifiBars)]
        }
        if let cellularMode = values.cellularMode { arguments += ["--cellularMode", cellularMode.rawValue] }
        if let cellularBars = values.cellularBars {
            try validate(cellularBars, range: 0...4, name: "cellular bars", arguments: arguments)
            arguments += ["--cellularBars", String(cellularBars)]
        }
        if let operatorName = values.operatorName { arguments += ["--operatorName", operatorName] }
        if let batteryState = values.batteryState { arguments += ["--batteryState", batteryState.rawValue] }
        if let batteryLevel = values.batteryLevel {
            try validate(batteryLevel, range: 0...100, name: "battery level", arguments: arguments)
            arguments += ["--batteryLevel", String(batteryLevel)]
        }
        guard arguments.count > 4 else {
            throw SimulatorControlError(
                code: "empty_status_bar_override",
                arguments: arguments,
                message: String(
                    localized: "simulator.control.statusBarValueRequired",
                    defaultValue: "A status bar override needs at least one value."
                )
            )
        }
        _ = try await output(arguments: arguments)
    }

    /// Clears every simulated status bar override.
    public func clearStatusBar(deviceID: String) async throws {
        _ = try await output(arguments: ["simctl", "status_bar", deviceID, "clear"])
    }

    /// Changes one appearance or accessibility setting supported by `simctl ui`.
    public func setInterface(deviceID: String, setting: SimulatorInterfaceSetting) async throws {
        let arguments: [String]
        switch setting {
        case let .appearance(value):
            arguments = ["simctl", "ui", deviceID, "appearance", value.rawValue]
        case let .increaseContrast(enabled):
            arguments = [
                "simctl", "ui", deviceID, "increase_contrast",
                enabled ? "enabled" : "disabled",
            ]
        case let .contentSize(value):
            arguments = ["simctl", "ui", deviceID, "content_size", value.rawValue]
        case let .contentSizeAdjustment(value):
            arguments = ["simctl", "ui", deviceID, "content_size", value.rawValue]
        case .liquidGlass, .colorFilter, .reduceMotion, .buttonShapes,
             .reduceTransparency, .voiceOver:
            throw SimulatorControlError(
                code: "worker_only_action",
                arguments: [],
                message: String(
                    localized: "simulator.control.liveAccessibilityRequiresHelper",
                    defaultValue: "This live accessibility setting requires the contained in-Simulator helper."
                )
            )
        }
        try await mutationGate.withLocks([.interface(deviceIdentifier: deviceID)]) {
            _ = try await output(arguments: arguments)
        }
    }

    func validate(
        _ value: Int,
        range: ClosedRange<Int>,
        name: String,
        arguments: [String]
    ) throws {
        guard range.contains(value) else {
            throw SimulatorControlError(
                code: "invalid_status_bar_value",
                arguments: arguments,
                message: String(
                    localized: "simulator.control.statusBarValueOutOfRange",
                    defaultValue: "The \(name) value must be from \(range.lowerBound) through \(range.upperBound)."
                )
            )
        }
    }


    func simctlPrivacyService(for service: SimulatorPrivacyService) -> String? {
        switch service {
        case .locationInUse:
            return "location"
        case .all, .calendar, .contactsLimited, .contacts, .location, .locationAlways,
             .photosAdd, .photos, .mediaLibrary, .microphone, .motion, .reminders,
             .siri:
            return service.rawValue
        case .photosLimited, .camera, .notifications, .criticalNotifications, .speech,
             .faceID, .userTracking, .homeKit:
            return nil
        }
    }
}
