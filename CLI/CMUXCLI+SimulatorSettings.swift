import CmuxSimulator
import Foundation

extension CMUXCLI {
    func simulatorPermissionsRequest(
        _ arguments: SimulatorArguments
    ) throws -> SimulatorAgentRequest {
        guard !arguments.readsStandardInput, arguments.file == nil,
              let verb = arguments.positionals.first?.lowercased() else {
            throw simulatorPermissionsUsageError()
        }
        let values = Array(arguments.positionals.dropFirst())
        if verb == "list" || verb == "read" {
            guard values.count <= 1, arguments.optionValue == nil else {
                throw simulatorPermissionsUsageError()
            }
            var params: [String: Any] = [:]
            if let bundleIdentifier = values.first {
                try validateSimulatorBundleIdentifier(bundleIdentifier)
                params["bundle_id"] = bundleIdentifier
            }
            return request(
                "simulator.permissions.read",
                params,
                output: .permissionsList
            )
        }

        let action: String
        switch verb {
        case "grant": action = "grant"
        case "revoke", "deny": action = "revoke"
        case "reset": action = "reset"
        default: throw simulatorPermissionsUsageError()
        }
        guard values.count == 2 || values.count == 3 else {
            throw simulatorPermissionsUsageError()
        }
        let rawPermission = values[0].lowercased()
        let bundleIdentifier = values[1]
        try validateSimulatorBundleIdentifier(bundleIdentifier)
        guard !(arguments.optionValue != nil && values.count == 3) else {
            throw simulatorPermissionsUsageError()
        }
        let value = (arguments.optionValue ?? (values.count == 3 ? values[2] : nil))?.lowercased()
        let normalized = try normalizeSimulatorPermission(
            action: action,
            permission: rawPermission,
            value: value
        )
        return request(
            "simulator.permissions.set",
            [
                "action": normalized.action,
                "service": normalized.service,
                "bundle_id": bundleIdentifier,
            ],
            timeout: simulatorOperationDeadlines.clientTimeout(
                for: normalized.service == "all"
                    ? simulatorOperationDeadlines.permissionResetAll
                    : simulatorOperationDeadlines.permissionMutation
            ),
            output: .permissionsUpdated(
                action: normalized.action,
                service: normalized.service,
                bundleIdentifier: bundleIdentifier
            )
        )
    }

    func simulatorInterfaceRequest(
        _ arguments: SimulatorArguments
    ) throws -> SimulatorAgentRequest {
        guard !arguments.readsStandardInput, arguments.file == nil,
              arguments.optionValue == nil else {
            throw simulatorInterfaceUsageError()
        }
        let values = arguments.positionals
        if values.isEmpty || values == ["status"] {
            return request(
                "simulator.ui.status",
                [:],
                timeout: simulatorOperationDeadlines.clientTimeout(
                    for: simulatorOperationDeadlines.interfaceRead
                ),
                output: .interfaceStatus
            )
        }

        let option: String
        let rawValue: String?
        if values.first?.lowercased() == "get", values.count == 2 {
            option = try normalizeSimulatorInterfaceOption(values[1])
            rawValue = nil
        } else if values.first?.lowercased() == "set", values.count == 3 {
            option = try normalizeSimulatorInterfaceOption(values[1])
            rawValue = values[2]
        } else if values.count == 1 {
            option = try normalizeSimulatorInterfaceOption(values[0])
            rawValue = nil
        } else if values.count == 2 {
            option = try normalizeSimulatorInterfaceOption(values[0])
            rawValue = values[1]
        } else {
            throw simulatorInterfaceUsageError()
        }

        guard let rawValue else {
            return request(
                "simulator.ui.status",
                [:],
                timeout: simulatorOperationDeadlines.clientTimeout(
                    for: simulatorOperationDeadlines.interfaceRead
                ),
                output: .interfaceValue(option: option)
            )
        }
        let value = try normalizeSimulatorInterfaceValue(rawValue, option: option)
        return request(
            "simulator.ui.set",
            ["option": option, "value": value],
            timeout: simulatorOperationDeadlines.clientTimeout(
                for: simulatorOperationDeadlines.interfaceMutation
            ),
            output: .interfaceUpdated(option: option)
        )
    }

    func normalizeSimulatorPermission(
        action: String,
        permission rawPermission: String,
        value: String?
    ) throws -> (action: String, service: String) {
        let alias: (permission: String, value: String?) = switch rawPermission {
        case "push", "notification": ("notifications", nil)
        case "photo-library", "photo": ("photos", nil)
        case "location-always": ("location", "always")
        case "location-in-use", "location_in_use", "location-inuse": ("location", "inuse")
        case "mic": ("microphone", nil)
        case "critical-notifications": ("notifications-critical", nil)
        case "face-id": ("faceid", nil)
        case "home-kit": ("homekit", nil)
        default: (rawPermission.replacingOccurrences(of: "_", with: "-"), nil)
        }
        let permission = alias.permission
        let value = value ?? alias.value
        let supported = [
            "all", "calendar", "contacts-limited", "contacts", "location",
            "location-always", "location-inuse", "photos-add", "photos",
            "photos-limited", "media-library", "microphone", "motion",
            "reminders", "siri", "camera", "notifications",
            "notifications-critical", "speech", "faceid", "user-tracking", "homekit",
        ]
        guard supported.contains(permission), permission != "all" || action == "reset" else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.simulator.error.unknownPermission",
                    defaultValue: "Unknown or unsupported Simulator permission: %@"
                ),
                rawPermission
            ))
        }
        guard permission != "all" || value == nil else {
            throw simulatorInvalidPermissionValue(value ?? "", permission: permission)
        }
        guard let value else { return (action, permission) }

        switch (permission, value) {
        case ("photos", "limited"):
            return (action, "photos-limited")
        case ("notifications", "critical"):
            return (action, "notifications-critical")
        case ("location", "always"):
            return (action, "location-always")
        case ("location", "inuse"), ("location", "in-use"):
            return (action, "location-inuse")
        case ("location", "never"):
            return ("revoke", "location")
        default:
            throw simulatorInvalidPermissionValue(value, permission: permission)
        }
    }

    func normalizeSimulatorInterfaceOption(_ raw: String) throws -> String {
        let option: String = switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "content-size": "text-size"
        case "button-shapes": "show-borders"
        case "voice-over": "voiceover"
        case let value: value
        }
        guard [
            "appearance", "liquid-glass", "color-filter", "text-size",
            "reduce-motion", "increase-contrast", "show-borders",
            "reduce-transparency", "voiceover",
        ].contains(option) else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.simulator.error.unknownUIOption",
                    defaultValue: "Unknown Simulator interface option: %@"
                ),
                raw
            ))
        }
        return option
    }

    func normalizeSimulatorInterfaceValue(
        _ raw: String,
        option: String
    ) throws -> String {
        let value = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        let normalized: String? = switch option {
        case "appearance": ["light", "dark"].contains(value) ? value : nil
        case "liquid-glass": ["clear", "tinted"].contains(value) ? value : nil
        case "color-filter": switch value {
            case "protanopia": "red-green"
            case "deuteranopia": "green-red"
            case "tritanopia": "blue-yellow"
            case "none", "grayscale", "red-green", "green-red", "blue-yellow": value
            default: nil
            }
        case "text-size": [
            "extra-small", "small", "medium", "large", "extra-large",
            "extra-extra-large", "extra-extra-extra-large", "accessibility-medium",
            "accessibility-large", "accessibility-extra-large",
            "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large",
            "increment", "decrement",
        ].contains(value) ? value : nil
        case "reduce-motion", "increase-contrast", "show-borders",
             "reduce-transparency", "voiceover": simulatorToggleValue(value)
        default: nil
        }
        guard let normalized else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.simulator.error.invalidUIValue",
                    defaultValue: "Invalid value '%@' for Simulator interface option %@"
                ),
                raw,
                option
            ))
        }
        return normalized
    }

    func validateSimulatorBundleIdentifier(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 255,
              simulatorASCIIAlphaNumeric(bytes[0]),
              bytes.allSatisfy({
                  simulatorASCIIAlphaNumeric($0) || $0 == 0x2D || $0 == 0x2E
              }) else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.simulator.error.invalidBundleIdentifier",
                    defaultValue: "Invalid Simulator application bundle identifier: %@"
                ),
                value
            ))
        }
    }

    func simulatorToggleValue(_ value: String) -> String? {
        switch value {
        case "on", "true", "enabled", "1", "yes": "on"
        case "off", "false", "disabled", "0", "no": "off"
        default: nil
        }
    }

    func simulatorASCIIAlphaNumeric(_ value: UInt8) -> Bool {
        (0x30...0x39).contains(value)
            || (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
    }

    func simulatorInvalidPermissionValue(_ value: String, permission: String) -> CLIError {
        CLIError(message: String.localizedStringWithFormat(
            String(
                localized: "cli.simulator.error.invalidPermissionValue",
                defaultValue: "Invalid value '%@' for Simulator permission %@"
            ),
            value,
            permission
        ))
    }

    func simulatorPermissionsUsageError() -> CLIError {
        CLIError(message: String(
            localized: "cli.simulator.permissions.usage",
            defaultValue: """
            Usage:
              cmux simulator permissions list [bundle-id] [--surface <id|ref|index>]
              cmux simulator permissions grant <permission> <bundle-id> [--value <value>] [--surface <id|ref|index>]
              cmux simulator permissions revoke <permission> <bundle-id> [--surface <id|ref|index>]
              cmux simulator permissions reset <permission|all> <bundle-id> [--surface <id|ref|index>]

            Values: photos limited; notifications critical; location always, inuse, or never.
            """
        ))
    }

    func simulatorInterfaceUsageError() -> CLIError {
        CLIError(message: String(
            localized: "cli.simulator.ui.usage",
            defaultValue: """
            Usage:
              cmux simulator ui [status] [--surface <id|ref|index>]
              cmux simulator ui [get] <option> [--surface <id|ref|index>]
              cmux simulator ui [set] <option> <value> [--surface <id|ref|index>]

            Options: appearance, liquid-glass, color-filter, text-size, reduce-motion, increase-contrast, show-borders, reduce-transparency, voiceover.
            """
        ))
    }
}
