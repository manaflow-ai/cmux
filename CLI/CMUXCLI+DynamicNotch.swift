import Foundation

extension CMUXCLI {
    func runDynamicNotchCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "status"
        let response: [String: Any]

        switch subcommand {
        case "status":
            guard commandArgs.count == 1 else {
                throw dynamicNotchUsageError()
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.settings"
            )
        case "enable", "on":
            guard commandArgs.count == 1 else {
                throw dynamicNotchUsageError()
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.configure",
                params: ["enabled": true]
            )
        case "disable", "off":
            guard commandArgs.count == 1 else {
                throw dynamicNotchUsageError()
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.configure",
                params: ["enabled": false]
            )
        case "toggle":
            guard commandArgs.count == 1 else {
                throw dynamicNotchUsageError()
            }
            let current = try client.sendV2(
                method: "notification.dynamic_notch.settings"
            )
            response = try client.sendV2(
                method: "notification.dynamic_notch.configure",
                params: [
                    "enabled": !((current["enabled"] as? Bool) ?? false)
                ]
            )
        case "position", "set-position":
            let arguments = try dynamicNotchPositionArguments(
                commandArgs,
                client: client
            )
            var params: [String: Any] = [
                "horizontal_position": arguments.position
            ]
            if let displayKey = arguments.displayKey {
                params["display_key"] = displayKey
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.configure",
                params: params
            )
        case "center":
            let displayKey = try dynamicNotchDisplayKey(
                from: Array(commandArgs.dropFirst()),
                client: client
            )
            var params: [String: Any] = ["horizontal_position": 0.5]
            if let displayKey {
                params["display_key"] = displayKey
            }
            response = try client.sendV2(
                method: "notification.dynamic_notch.configure",
                params: params
            )
        case "reset-position":
            let displayKey = try dynamicNotchDisplayKey(
                from: Array(commandArgs.dropFirst()),
                client: client
            )
            if let displayKey {
                response = try client.sendV2(
                    method: "notification.dynamic_notch.configure",
                    params: [
                        "display_key": displayKey,
                        "reset_display_position": true,
                    ]
                )
            } else {
                response = try client.sendV2(
                    method: "notification.dynamic_notch.configure",
                    params: ["horizontal_position": 0.5]
                )
            }
        default:
            throw dynamicNotchUsageError()
        }

        if jsonOutput {
            print(jsonString(response))
            return
        }
        let state =
            (response["enabled"] as? Bool) == true
            ? String(
                localized: "cli.dynamicNotch.state.enabled",
                defaultValue: "enabled"
            )
            : String(
                localized: "cli.dynamicNotch.state.disabled",
                defaultValue: "disabled"
            )
        let statusFormat = String(
            localized: "cli.dynamicNotch.status",
            defaultValue: "Dynamic Notch: %@"
        )
        print(String.localizedStringWithFormat(statusFormat, state))

        let position =
            (response["horizontal_position"] as? NSNumber)?
            .doubleValue ?? 0.5
        let positionFormat = String(
            localized: "cli.dynamicNotch.horizontalPosition",
            defaultValue: "Default horizontal position: %.2f"
        )
        print(String.localizedStringWithFormat(positionFormat, position))
        printDynamicNotchDisplays(response["displays"])
    }

    func dynamicNotchUsage() -> String {
        String(
            localized: "cli.help.dynamicNotch",
            defaultValue: """
                Usage: cmux dynamic-notch <status|enable|disable|toggle|position|center|reset-position> [value] [--display <id|name|key>] [--json]

                Control the default interactive Dynamic Notch notification tray.

                Subcommands:
                  status                  Print enablement and every display.
                  enable|on               Use Dynamic Notch for default notifications.
                  disable|off             Use macOS Notification Center by default.
                  toggle                  Toggle the default notification delivery.
                  position <0...1>        Set the synthetic notch position.
                  position left|center|right
                                          Set a named synthetic notch position.
                  position <value> --display <id|name|key>
                                          Move one connected display's notch.
                  center [--display <id|name|key>]
                                          Center all displays or one display.
                  reset-position --display <id|name|key>
                                          Restore one display to the global position.

                Explicit `cmux notify --delivery notch` calls still show the tray
                when its default delivery is disabled.
                """
        )
    }

    private func dynamicNotchPosition(_ raw: String) throws -> Double {
        switch raw.lowercased() {
        case "left":
            return 0
        case "center", "middle":
            return 0.5
        case "right":
            return 1
        default:
            guard let value = Double(raw),
                value.isFinite,
                (0...1).contains(value)
            else {
                throw CLIError(
                    message: String(
                        localized: "cli.dynamicNotch.error.invalidPosition",
                        defaultValue:
                            "Dynamic Notch position must be left, center, right, or a number from 0 to 1."
                    ),
                    exitCode: 2
                )
            }
            return value
        }
    }

    private func dynamicNotchPositionArguments(
        _ commandArgs: [String],
        client: SocketClient
    ) throws -> (position: Double, displayKey: String?) {
        guard commandArgs.count == 2 || commandArgs.count == 4 else {
            throw dynamicNotchUsageError()
        }
        let position = try dynamicNotchPosition(commandArgs[1])
        let displayKey = try dynamicNotchDisplayKey(
            from: Array(commandArgs.dropFirst(2)),
            client: client
        )
        return (position, displayKey)
    }

    private func dynamicNotchDisplayKey(
        from arguments: [String],
        client: SocketClient
    ) throws -> String? {
        guard !arguments.isEmpty else { return nil }
        guard arguments.count == 2,
            arguments[0] == "--display"
        else {
            throw dynamicNotchUsageError()
        }
        let selector = arguments[1]
        let status = try client.sendV2(
            method: "notification.dynamic_notch.settings"
        )
        let displays = status["displays"] as? [[String: Any]] ?? []
        let normalized = selector.lowercased()
        let matches = displays.filter { display in
            let key = display["key"] as? String ?? ""
            let name = display["name"] as? String ?? ""
            let id = (display["id"] as? NSNumber)?.stringValue ?? ""
            return key == selector
                || id == selector
                || name.lowercased() == normalized
        }
        guard matches.count == 1,
            let key = matches[0]["key"] as? String
        else {
            let available = displays.compactMap { display -> String? in
                guard let name = display["name"] as? String,
                    let key = display["key"] as? String
                else {
                    return nil
                }
                let id = (display["id"] as? NSNumber)?.stringValue ?? "?"
                return "\(name) (\(id), \(key))"
            }.joined(separator: ", ")
            throw CLIError(
                message: String.localizedStringWithFormat(
                    String(
                        localized:
                            "cli.dynamicNotch.error.displayNotFound",
                        defaultValue:
                            "Display '%@' did not match exactly one connected display. Available: %@"
                    ),
                    selector,
                    available
                ),
                exitCode: 2
            )
        }
        return key
    }

    private func printDynamicNotchDisplays(_ rawDisplays: Any?) {
        guard let displays = rawDisplays as? [[String: Any]],
            !displays.isEmpty
        else {
            return
        }
        print(
            String(
                localized: "cli.dynamicNotch.displays",
                defaultValue: "Displays:"
            )
        )
        let format = String(
            localized: "cli.dynamicNotch.display",
            defaultValue: "  %@ (%@): %.2f [%@]"
        )
        for display in displays {
            let key = display["key"] as? String ?? ""
            let name = display["name"] as? String ?? key
            let id = (display["id"] as? NSNumber)?.stringValue ?? "?"
            let position =
                (display["horizontal_position"] as? NSNumber)?
                .doubleValue ?? 0.5
            print(
                String.localizedStringWithFormat(
                    format,
                    name,
                    id,
                    position,
                    key
                )
            )
        }
    }

    private func dynamicNotchUsageError() -> CLIError {
        CLIError(
            message: String(
                localized: "cli.dynamicNotch.error.usage",
                defaultValue:
                    "Usage: cmux dynamic-notch <status|enable|disable|toggle|position|center|reset-position> [value] [--display <id|name|key>] [--json]"
            ),
            exitCode: 2
        )
    }
}
