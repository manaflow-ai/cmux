import Foundation

extension CMUXCLI {
    func printSimulatorAgentResult(
        _ payload: [String: Any],
        output: SimulatorAgentOutput,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        if jsonOutput || output == .cameraStatus {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        switch output {
        case .completed:
            print(String(localized: "cli.simulator.output.accepted", defaultValue: "Completed"))
        case .eventLog:
            for event in payload["events"] as? [[String: Any]] ?? [] {
                let timestamp = simulatorTerminalText(event["timestamp"] as? String ?? "")
                let action = simulatorTerminalText(event["action"] as? String ?? "")
                let summary = simulatorTerminalText(event["summary"] as? String ?? "")
                print("\(timestamp)\t\(action)\t\(summary)")
            }
        case .cameraStatus:
            break
        case .permissionsList:
            printSimulatorPermissions(payload)
        case let .permissionsUpdated(action, service, bundleIdentifier):
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.simulator.output.permissionUpdated",
                    defaultValue: "%@ %@ for %@"
                ),
                simulatorTerminalText(action),
                simulatorTerminalText(service),
                simulatorTerminalText(bundleIdentifier)
            ))
        case .interfaceStatus:
            printSimulatorInterfaceSettings(payload)
        case let .interfaceValue(option):
            let settings = payload["settings"] as? [String: Any]
            print(simulatorTerminalText(settings?[option] as? String ?? ""))
        case let .interfaceUpdated(option):
            let settings = payload["settings"] as? [String: Any]
            let value = settings?[option] as? String ?? ""
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.simulator.output.interfaceUpdated",
                    defaultValue: "Set %@ to %@"
                ),
                simulatorTerminalText(option),
                simulatorTerminalText(value)
            ))
        case .accessibility:
            printSimulatorAccessibility(payload)
        case .foregroundApplication:
            printSimulatorForegroundApplication(payload)
        }
    }

    func printSimulatorPermissions(_ payload: [String: Any]) {
        if let applications = payload["applications"] as? [[String: Any]] {
            guard !applications.isEmpty else {
                print(String(
                    localized: "cli.simulator.output.noPermissions",
                    defaultValue: "No permission values"
                ))
                return
            }
            for application in applications.sorted(by: {
                ($0["bundle_id"] as? String ?? "") < ($1["bundle_id"] as? String ?? "")
            }) {
                let bundleIdentifier = simulatorTerminalText(application["bundle_id"] as? String ?? "?")
                let permissions = application["permissions"] as? [String: Any] ?? [:]
                for key in permissions.keys.sorted() {
                    print("\(bundleIdentifier)\t\(simulatorTerminalText(key))\t"
                        + simulatorTerminalText(permissions[key] as? String ?? "unknown"))
                }
            }
            if payload["truncated"] as? Bool == true {
                print(String(
                    localized: "cli.simulator.output.permissionsTruncated",
                    defaultValue: "Permission results were truncated at 256 applications"
                ))
            }
            return
        }
        let permissions = payload["permissions"] as? [String: Any] ?? [:]
        guard !permissions.isEmpty else {
            print(String(
                localized: "cli.simulator.output.noPermissions",
                defaultValue: "No permission values"
            ))
            return
        }
        for key in permissions.keys.sorted() {
            print("\(simulatorTerminalText(key))\t"
                + simulatorTerminalText(permissions[key] as? String ?? "unknown"))
        }
    }

    func printSimulatorInterfaceSettings(_ payload: [String: Any]) {
        let settings = payload["settings"] as? [String: Any] ?? [:]
        guard !settings.isEmpty else {
            print(String(
                localized: "cli.simulator.output.noInterfaceSettings",
                defaultValue: "No interface settings"
            ))
            return
        }
        for key in settings.keys.sorted() {
            print("\(simulatorTerminalText(key))\t"
                + simulatorTerminalText(settings[key] as? String ?? "unsupported"))
        }
    }

    func simulatorPoint(_ x: String, _ y: String) throws -> (x: Double, y: Double) {
        guard let x = Double(x), let y = Double(y), x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y) else {
            throw CLIError(message: String(
                localized: "cli.simulator.error.invalidCoordinate",
                defaultValue: "Simulator coordinates must be numbers from 0 through 1"
            ))
        }
        return (x, y)
    }

    func oneSimulatorValue(_ arguments: SimulatorArguments) -> String? {
        guard !arguments.readsStandardInput, arguments.file == nil,
              arguments.positionals.count == 1 else { return nil }
        return arguments.positionals[0]
    }

    func simulatorOnOff(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "on", "true", "1": true
        case "off", "false", "0": false
        default: nil
        }
    }

    func simulatorButtonName(_ raw: String) -> String {
        let normalized = raw.lowercased()
        return switch normalized {
        case "swipe-home", "swipe_home", "swipehome": "swipeHome"
        case "app-switcher", "app_switcher", "appswitcher": "appSwitcher"
        case "side-button", "side_button", "sidebutton": "sideButton"
        case "volume-up", "volume_up", "volumeup": "volumeUp"
        case "volume-down", "volume_down", "volumedown": "volumeDown"
        case "watch-side-button", "watch_side_button", "watchsidebutton": "watchSideButton"
        default: normalized
        }
    }

    func simulatorCADiagnosticName(_ raw: String) -> String {
        let normalized = raw.lowercased()
        return switch normalized {
        case "slow-animations", "slow_animations", "slowanimations": "slowAnimations"
        default: normalized
        }
    }

    func simulatorArgumentsError(_ command: String) -> CLIError {
        CLIError(message: String.localizedStringWithFormat(
            String(
                localized: "cli.simulator.error.invalidArguments",
                defaultValue: "Invalid arguments for simulator %@"
            ),
            command
        ))
    }

    func printSimulatorAccessibility(_ payload: [String: Any]) {
        struct PendingNode {
            let value: [String: Any]
            let depth: Int
        }
        let roots = payload["roots"] as? [[String: Any]] ?? []
        var pending = roots.reversed().map { PendingNode(value: $0, depth: 0) }
        var emitted = 0
        while let current = pending.popLast(), emitted < 500 {
            emitted += 1
            let role = simulatorTerminalText(current.value["type"] as? String ?? "?")
            let label = simulatorTerminalText(current.value["AXLabel"] as? String ?? "")
            let value = simulatorTerminalText(current.value["AXValue"] as? String ?? "")
            let identifier = simulatorTerminalText(current.value["AXUniqueId"] as? String ?? "")
            let indentation = String(repeating: "  ", count: min(current.depth, 16))
            print("\(indentation)\(role)\t\(label)\t\(value)\t\(identifier)")
            let children = current.value["children"] as? [[String: Any]] ?? []
            for child in children.reversed() {
                pending.append(PendingNode(value: child, depth: current.depth + 1))
            }
        }
        if payload["truncated"] as? Bool == true || !pending.isEmpty {
            print(String(
                localized: "cli.simulator.output.accessibilityTruncated",
                defaultValue: "Accessibility results reached the 500-element limit"
            ))
        }
    }

    func printSimulatorForegroundApplication(_ payload: [String: Any]) {
        guard let application = payload["application"] as? [String: Any] else {
            print(String(
                localized: "cli.simulator.output.noForegroundApplication",
                defaultValue: "No foreground application"
            ))
            return
        }
        let bundleIdentifier = simulatorTerminalText(application["bundle_id"] as? String ?? "?")
        let name = simulatorTerminalText(application["name"] as? String ?? bundleIdentifier)
        let processIdentifier = simulatorTerminalText(
            application["pid"].map { String(describing: $0) } ?? ""
        )
        let executable = simulatorTerminalText(application["executable"] as? String ?? "")
        let bundlePath = simulatorTerminalText(application["bundle_path"] as? String ?? "")
        print("\(name)\t\(bundleIdentifier)\t\(processIdentifier)\t\(executable)\t\(bundlePath)")
    }

    func simulatorTerminalText(_ value: String) -> String {
        Self.sanitizeForTerminal(value)
    }
}
