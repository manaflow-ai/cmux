import Foundation

extension CMUXCLI {
    private static let simulatorTextLimit = 4_096
    private static let simulatorInspectorLimit = 1_024 * 1_024

    var simulatorCommandUsageLine: String {
        String(
            localized: "cli.help.simulator",
            defaultValue: "simulator <subcommand> [args] [--surface <id|ref|index>]"
        )
    }

    var iosCommandUsageLine: String {
        String(
            localized: "cli.help.ios",
            defaultValue: "ios <subcommand> [args] [--surface <id|ref|index>]"
        )
    }

    struct SimulatorArguments {
        var surface: String?
        var readsStandardInput = false
        var file: String?
        var optionValue: String?
        var positionals: [String] = []
    }

    func simulatorSubcommandUsage() -> String {
        let usage = String(
            localized: "cli.simulator.usage",
            defaultValue: """
            Usage: cmux simulator <subcommand> [args] [--surface <id|ref|index>]

            Subcommands:
              type [text] [--stdin|--file <path>]  Type text and wait for transmission completion
              tap <x> <y> [x2 y2]                 Send a correlated one- or two-finger tap
              gesture <json> [--stdin|--file]      Send 1...256 ordered normalized touch events
              multitouch <json> [--stdin|--file]  Send ordered two-finger touch events
              swipe <x1> <y1> <x2> <y2> [steps]  Send a sampled swipe
              button <name>                       Press a Simulator hardware button
              rotate <orientation>                Rotate to a logical orientation
              ca <diagnostic> <on|off>             Toggle a Core Animation diagnostic
              memory-warning                      Simulate a memory warning
              event-log [limit]                   Print recent Simulator events
              camera <configure|switch|mirror|status> ...
              permissions <list|grant|revoke|reset> ...
              ui [status|get|set] [option] [value]
              targets                             Refresh and print Web Inspector targets
              attach <target-id>                  Attach the native Web Inspector session
              send [json] [--stdin|--file <path>] Send a raw JSON inspector command
              highlight <on|off>                  Highlight the attached page
              release                             Release the attached page

            Each command waits for its correlated Simulator-worker result. `send`
            prints the raw response carrying the same JSON request id.
            """
        )
        let inspection = String(
            localized: "cli.simulator.usage.inspection",
            defaultValue: """
            Additional inspection commands:
              accessibility                       Print the bounded native accessibility tree
              foreground                          Print the foreground application
            """
        )
        return "\(usage)\n\n\(inspection)"
    }

    func iosSubcommandUsage() -> String {
        String(
            localized: "cli.ios.usage",
            defaultValue: """
            Usage: cmux ios <subcommand> [args] [--surface <id|ref|index>]

            Every native `cmux simulator` subcommand is accepted unchanged.

            Additional subcommands:
              context [--udid]                    Print the selected Simulator identity
              xcodebuildmcp <workflow> <tool> ... Run XcodeBuildMCP against that Simulator

            Examples:
              cmux ios context --json
              cmux ios rotate landscape-left
              cmux ios xcodebuildmcp simulator screenshot --return-format path
            """
        )
    }

    func runIOSNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: iosSubcommandUsage())
        }
        switch subcommand {
        case "context":
            var values = Array(commandArgs.dropFirst())
            let udidOnly = values.contains("--udid")
            values.removeAll { $0 == "--udid" }
            let surface = try removeIOSSurfaceOption(from: &values)
            guard values.isEmpty else { throw CLIError(message: iosSubcommandUsage()) }
            let payload = try iosContextPayload(
                surface: surface, client: client, windowOverride: windowOverride
            )
            if udidOnly {
                guard let simulatorID = payload["simulator_id"] as? String else {
                    throw missingIOSSimulatorIdentifier()
                }
                print(simulatorID)
            } else if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                printIOSContext(payload)
            }
        case "xcodebuildmcp", "xbmcp":
            var arguments = Array(commandArgs.dropFirst())
            let surface = try removeIOSSurfaceOption(from: &arguments)
            guard arguments.count >= 2 else { throw CLIError(message: iosSubcommandUsage()) }
            let payload = try iosContextPayload(
                surface: surface, client: client, windowOverride: windowOverride
            )
            guard let simulatorID = payload["simulator_id"] as? String else {
                throw missingIOSSimulatorIdentifier()
            }
            if !arguments.contains("--simulator-id")
                && !arguments.contains(where: { $0.hasPrefix("--simulator-id=") }) {
                arguments.append(contentsOf: ["--simulator-id", simulatorID])
            }
            try execInteractiveProgram(launchPath: "xcodebuildmcp", arguments: arguments)
        default:
            try runSimulatorNamespace(
                commandArgs: commandArgs, client: client, jsonOutput: jsonOutput,
                idFormat: idFormat, windowOverride: windowOverride
            )
        }
    }

    private func iosContextPayload(
        surface: String?, client: SocketClient, windowOverride: String?
    ) throws -> [String: Any] {
        let window = try normalizeWindowHandle(windowOverride, client: client)
        let normalizedSurface = try normalizeSurfaceHandle(
            surface, client: client, windowHandle: window
        )
        var params: [String: Any] = [:]
        if let window { params["window_id"] = window }
        if let normalizedSurface { params["surface_id"] = normalizedSurface }
        return try client.sendV2(method: "simulator.context", params: params)
    }

    private func removeIOSSurfaceOption(from arguments: inout [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: "--surface") else { return nil }
        guard index + 1 < arguments.count else { throw CLIError(message: iosSubcommandUsage()) }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    private func missingIOSSimulatorIdentifier() -> CLIError {
        CLIError(message: String(
            localized: "cli.ios.error.missingSimulatorID",
            defaultValue: "The selected iOS pane has no Simulator identifier"
        ))
    }

    private func printIOSContext(_ payload: [String: Any]) {
        for key in [
            "simulator_id", "device_name", "runtime_id", "state", "orientation", "surface_ref",
        ] {
            if let value = payload[key], !(value is NSNull) { print("\(key)=\(value)") }
        }
    }

    func runSimulatorNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: simulatorSubcommandUsage())
        }
        let parsed = try parseSimulatorArguments(Array(commandArgs.dropFirst()))
        let window = try normalizeWindowHandle(windowOverride, client: client)
        let surface = try normalizeSurfaceHandle(
            parsed.surface,
            client: client,
            windowHandle: window
        )
        var params: [String: Any] = [:]
        if let window { params["window_id"] = window }
        if let surface { params["surface_id"] = surface }

        if let request = try simulatorAgentRequest(subcommand: subcommand, arguments: parsed) {
            params.merge(request.params, uniquingKeysWith: { _, new in new })
            let payload = try client.sendV2(
                method: request.method,
                params: params,
                responseTimeout: request.timeout
            )
            printSimulatorAgentResult(payload, output: request.output, jsonOutput: jsonOutput,
                                      idFormat: idFormat)
            return
        }

        let method: String
        let responseTimeout: TimeInterval?
        switch subcommand {
        case "type":
            params["text"] = try simulatorSourceValue(
                parsed,
                maximumBytes: Self.simulatorTextLimit
            )
            method = "simulator.type"
            responseTimeout = 130
        case "targets":
            try requireNoSimulatorSource(parsed, subcommand: subcommand)
            method = "simulator.web_inspector.targets"
            responseTimeout = 25
        case "attach":
            guard parsed.positionals.count == 1,
                  !parsed.positionals[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !parsed.readsStandardInput,
                  parsed.file == nil else {
                throw CLIError(message: simulatorSubcommandUsage())
            }
            params["target_id"] = parsed.positionals[0]
            method = "simulator.web_inspector.attach"
            responseTimeout = 25
        case "send":
            params["json"] = try simulatorSourceValue(
                parsed,
                maximumBytes: Self.simulatorInspectorLimit
            )
            method = "simulator.web_inspector.send"
            responseTimeout = 25
        case "highlight":
            guard parsed.positionals.count == 1,
                  !parsed.readsStandardInput,
                  parsed.file == nil else {
                throw CLIError(message: simulatorSubcommandUsage())
            }
            switch parsed.positionals[0].lowercased() {
            case "on", "true", "1": params["enabled"] = true
            case "off", "false", "0": params["enabled"] = false
            default:
                throw CLIError(message: String(
                    localized: "cli.simulator.error.invalidHighlight",
                    defaultValue: "simulator highlight requires on or off"
                ))
            }
            method = "simulator.web_inspector.highlight"
            responseTimeout = 25
        case "release":
            try requireNoSimulatorSource(parsed, subcommand: subcommand)
            method = "simulator.web_inspector.release"
            responseTimeout = 25
        default:
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.simulator.error.unknownSubcommand",
                    defaultValue: "Unknown simulator subcommand: %@"
                ),
                subcommand
            ))
        }

        let payload = try client.sendV2(
            method: method,
            params: params,
            responseTimeout: responseTimeout
        )
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else if subcommand == "targets" {
            printSimulatorTargets(payload)
        } else if subcommand == "type" {
            let count = (payload["character_count"] as? Int) ?? 0
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.simulator.output.typed",
                    defaultValue: "Typed %lld character(s)"
                ),
                count
            ))
        } else if subcommand == "send" {
            print(payload["response_json"] as? String ?? "")
        } else {
            print(String(
                localized: "cli.simulator.output.accepted",
                defaultValue: "Completed"
            ))
        }
    }

}
