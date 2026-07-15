import CmuxSimulator
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
              tools <show|hide|toggle>             Control the Simulator tools inspector
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
            Usage: cmux ios <subcommand> [args] [--surface <ref>]

            Every native `cmux simulator` subcommand is accepted unchanged.

            Additional subcommands:
              list [--workspace <ref>]            List Simulator panes and device identifiers
              context [--udid]                    Print one selected Simulator identity
              select <device-udid>                Bind a pane to an iPhone or iPad Simulator
              screenshot [--out <path>]           Capture one or many selected Simulators

            Examples:
              cmux ios list --json
              cmux ios screenshot --surface surface:2 --out phone.png
              cmux ios screenshot --all --out screenshots/
              cmux ios rotate landscape-left
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
        case "list":
            var values = Array(commandArgs.dropFirst())
            let workspace = try removeIOSOption("--workspace", from: &values)
            guard values.isEmpty else { throw CLIError(message: iosSubcommandUsage()) }
            let targets = try iosTargetPayloads(
                workspace: workspace, client: client, windowOverride: windowOverride
            )
            if jsonOutput {
                print(jsonString(formatIDs(["targets": targets], mode: idFormat)))
            } else {
                printIOSTargets(targets)
            }
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
        case "screenshot":
            try runIOSScreenshot(
                commandArgs: Array(commandArgs.dropFirst()),
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )
        default:
            try runSimulatorNamespace(
                commandArgs: commandArgs, client: client, jsonOutput: jsonOutput,
                idFormat: idFormat, windowOverride: windowOverride
            )
        }
    }

    private func iosTargetPayloads(
        workspace: String?, client: SocketClient, windowOverride: String?
    ) throws -> [[String: Any]] {
        let window = try normalizeWindowHandle(windowOverride, client: client)
        let requestedWorkspace = workspace
            ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let workspaceID: String
        if let requestedWorkspace,
           let normalized = try normalizeWorkspaceHandle(
               requestedWorkspace, client: client, windowHandle: window
           ) {
            workspaceID = normalized
        } else {
            var params: [String: Any] = [:]
            if let window { params["window_id"] = window }
            let current = try client.sendV2(method: "workspace.current", params: params)
            guard let resolved = (current["workspace_id"] as? String)
                ?? (current["workspace_ref"] as? String) else {
                throw CLIError(message: iosSubcommandUsage())
            }
            workspaceID = resolved
        }
        var listParams: [String: Any] = ["workspace_id": workspaceID]
        if let window { listParams["window_id"] = window }
        let listed = try client.sendV2(method: "surface.list", params: listParams)
        let surfaces = (listed["surfaces"] as? [[String: Any]] ?? []).filter {
            ($0["type"] as? String) == "simulator"
        }
        return try surfaces.map { surface in
            guard let handle = (surface["id"] as? String) ?? (surface["ref"] as? String) else {
                throw CLIError(message: iosSubcommandUsage())
            }
            var target: [String: Any] = [
                "surface_id": surface["id"] ?? NSNull(),
                "surface_ref": surface["ref"] ?? handle,
                "simulator_id": surface["simulator_id"] ?? NSNull(),
                "runtime_id": surface["runtime_id"] ?? NSNull(),
                "device_type_id": surface["device_type_id"] ?? NSNull(),
            ]
            target["workspace_id"] = listed["workspace_id"] ?? workspaceID
            target["workspace_ref"] = listed["workspace_ref"] ?? NSNull()
            return target
        }
    }

    private func runIOSScreenshot(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        var values = commandArgs
        let surfaces = try removeIOSOptions("--surface", from: &values)
        let workspace = try removeIOSOption("--workspace", from: &values)
        let output = try removeIOSOption("--out", from: &values)
        let all = values.contains("--all")
        values.removeAll { $0 == "--all" }
        guard values.isEmpty, all || surfaces.count <= 1 else {
            throw CLIError(message: iosSubcommandUsage())
        }
        let targets: [[String: Any]]
        if all {
            guard surfaces.isEmpty else { throw CLIError(message: iosSubcommandUsage()) }
            targets = try iosTargetPayloads(
                workspace: workspace, client: client, windowOverride: windowOverride
            )
        } else if let surface = surfaces.first {
            guard workspace == nil else { throw CLIError(message: iosSubcommandUsage()) }
            targets = [try iosContextPayload(
                surface: surface, client: client, windowOverride: windowOverride
            )]
        } else {
            let candidates = try iosTargetPayloads(
                workspace: workspace, client: client, windowOverride: windowOverride
            )
            guard candidates.count == 1 else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.ios.error.ambiguousTargets",
                        defaultValue: "Found %lld iOS Simulator panes; pass --surface <ref> or --all"
                    ), candidates.count
                ))
            }
            targets = candidates
        }
        guard !targets.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.ios.error.noTargets",
                defaultValue: "No matching iOS Simulator panes were found"
            ))
        }
        let outputURL = output.map { URL(fileURLWithPath: $0).standardizedFileURL }
        if let outputURL {
            var isDirectory: ObjCBool = false
            let outputExists = FileManager.default.fileExists(
                atPath: outputURL.path,
                isDirectory: &isDirectory
            )
            if targets.count == 1, outputExists, isDirectory.boolValue {
                throw CLIError(message: String(
                    localized: "cli.ios.error.outputFileRequired",
                    defaultValue: "--out must name a file when capturing one Simulator"
                ))
            }
            guard targets.count == 1 || (outputExists && isDirectory.boolValue) else {
                throw CLIError(message: String(
                    localized: "cli.ios.error.outputDirectoryRequired",
                    defaultValue: "--out must name an existing directory when capturing multiple Simulators"
                ))
            }
        }
        let captures = try targets.map { target -> [String: Any] in
            guard let simulatorID = target["simulator_id"] as? String,
                  let surfaceRef = target["surface_ref"] as? String else {
                if all {
                    return [
                        "surface_ref": target["surface_ref"] ?? NSNull(),
                        "error": target["error"] ?? missingIOSSimulatorIdentifier().message,
                    ]
                }
                throw missingIOSSimulatorIdentifier()
            }
            let destination: URL
            if let outputURL, targets.count == 1 {
                destination = outputURL
            } else {
                let directory = outputURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                let safeRef = surfaceRef.replacingOccurrences(of: ":", with: "-")
                destination = directory.appendingPathComponent("ios-\(safeRef).png")
            }
            let result = CLIProcessRunner.runProcess(
                executablePath: "/usr/bin/xcrun",
                arguments: ["simctl", "io", simulatorID, "screenshot", destination.path],
                timeout: 30
            )
            guard result.status == 0 else {
                if all {
                    return [
                        "simulator_id": simulatorID,
                        "surface_ref": surfaceRef,
                        "error": result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                    ]
                }
                throw CLIError(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return [
                "path": destination.path,
                "simulator_id": simulatorID,
                "surface_ref": surfaceRef,
            ]
        }
        if jsonOutput {
            print(jsonString(formatIDs(["captures": captures], mode: idFormat)))
        } else {
            captures.forEach { capture in
                if let path = capture["path"] as? String {
                    print(path)
                } else if let error = capture["error"] as? String {
                    let surface = capture["surface_ref"] as? String ?? "?"
                    cliWriteStderr("\(surface): \(error)\n")
                }
            }
        }
        if captures.contains(where: { $0["error"] != nil }) {
            throw CLIError(message: String(
                localized: "cli.ios.error.screenshotFailures",
                defaultValue: "One or more iOS Simulator screenshots failed"
            ))
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
        return try client.sendV2(
            method: "simulator.context",
            params: params,
            responseTimeout: simulatorOperationDeadlines.clientTimeout(
                for: simulatorOperationDeadlines.inspectionRead
            )
        )
    }

    private func removeIOSSurfaceOption(from arguments: inout [String]) throws -> String? {
        try removeIOSOption("--surface", from: &arguments)
    }

    private func removeIOSOption(_ name: String, from arguments: inout [String]) throws -> String? {
        let values = try removeIOSOptions(name, from: &arguments)
        guard values.count <= 1 else { throw CLIError(message: iosSubcommandUsage()) }
        return values.first
    }

    private func removeIOSOptions(_ name: String, from arguments: inout [String]) throws -> [String] {
        var values: [String] = []
        while let index = arguments.firstIndex(of: name) {
            guard index + 1 < arguments.count else { throw CLIError(message: iosSubcommandUsage()) }
            values.append(arguments[index + 1])
            arguments.removeSubrange(index...(index + 1))
        }
        return values
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

    private func printIOSTargets(_ targets: [[String: Any]]) {
        guard !targets.isEmpty else {
            print(String(localized: "cli.ios.output.noTargets", defaultValue: "No iOS Simulator panes"))
            return
        }
        for target in targets {
            print([
                target["surface_ref"] as? String ?? "?",
                target["device_name"] as? String ?? "?",
                target["simulator_id"] as? String ?? "?",
                target["state"] as? String ?? "?",
            ].joined(separator: "\t"))
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
            responseTimeout = simulatorOperationDeadlines.clientTimeout(for: 20)
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
