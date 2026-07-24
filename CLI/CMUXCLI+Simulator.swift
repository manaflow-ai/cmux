import CmuxSimulator
import Foundation

extension CMUXCLI {
    private static let simulatorTextLimit = 4_096
    private static let simulatorInspectorLimit = 1_024 * 1_024
    private static let iosScreenshotBatchLimit = 8
    private static let iosScreenshotBatchTimeout: TimeInterval = 600

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
              screenshot [--out <path>]           Capture one or up to 8 selected Simulators

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
        let requestedWorkspace = workspace ?? (window == nil
            ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
            : nil)
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
                "device_name": surface["device_name"] ?? NSNull(),
                "state": surface["state"] ?? NSNull(),
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
        var targets: [[String: Any]]
        let targetsRequireContextResolution: Bool
        if all {
            guard surfaces.isEmpty else { throw CLIError(message: iosSubcommandUsage()) }
            targets = try iosTargetPayloads(
                workspace: workspace, client: client, windowOverride: windowOverride
            )
            targetsRequireContextResolution = true
        } else if let surface = surfaces.first {
            guard workspace == nil else { throw CLIError(message: iosSubcommandUsage()) }
            targets = [try iosScreenshotContextPayload(
                surface: surface, client: client, windowOverride: windowOverride
            )]
            targetsRequireContextResolution = false
        } else if workspace == nil {
            targets = [try iosScreenshotContextPayload(
                surface: nil, client: client, windowOverride: windowOverride
            )]
            targetsRequireContextResolution = false
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
            targetsRequireContextResolution = true
        }
        guard !targets.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.ios.error.noTargets",
                defaultValue: "No matching iOS Simulator panes were found"
            ))
        }
        if all, targets.count > Self.iosScreenshotBatchLimit {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.ios.error.screenshotBatchLimit",
                    defaultValue: "Found %lld iOS Simulator panes; screenshot --all supports at most 8"
                ),
                targets.count
            ))
        }
        let batchDeadline = all
            ? ProcessInfo.processInfo.systemUptime + Self.iosScreenshotBatchTimeout
            : nil
        if targetsRequireContextResolution {
            var resolvedTargets: [[String: Any]] = []
            resolvedTargets.reserveCapacity(targets.count)
            for target in targets {
                guard let surfaceRef = target["surface_ref"] as? String else {
                    throw missingIOSSurfaceReference()
                }
                if let batchDeadline,
                   ProcessInfo.processInfo.systemUptime >= batchDeadline {
                    var failedTarget = target
                    failedTarget["error"] = iosScreenshotBatchTimeoutMessage()
                    resolvedTargets.append(failedTarget)
                    continue
                }
                do {
                    resolvedTargets.append(try iosScreenshotContextPayload(
                        surface: surfaceRef,
                        client: client,
                        windowOverride: windowOverride,
                        responseTimeout: batchDeadline.map {
                            max(1, $0 - ProcessInfo.processInfo.systemUptime)
                        }
                    ))
                } catch {
                    guard all else { throw error }
                    var failedTarget = target
                    failedTarget["error"] = (error as? CLIError)?.message ?? error.localizedDescription
                    resolvedTargets.append(failedTarget)
                }
            }
            targets = resolvedTargets
        }
        let outputURL = output.map { URL(fileURLWithPath: $0).standardizedFileURL }
        if let outputURL {
            var isDirectory: ObjCBool = false
            let outputExists = FileManager.default.fileExists(
                atPath: outputURL.path,
                isDirectory: &isDirectory
            )
            if all {
                guard outputExists, isDirectory.boolValue else {
                    throw CLIError(message: String(
                        localized: "cli.ios.error.outputDirectoryRequired",
                        defaultValue: "--out must name an existing directory when capturing multiple Simulators"
                    ))
                }
            } else if targets.count == 1, outputExists, isDirectory.boolValue {
                throw CLIError(message: String(
                    localized: "cli.ios.error.outputFileRequired",
                    defaultValue: "--out must name a file when capturing one Simulator"
                ))
            } else if targets.count != 1, !(outputExists && isDirectory.boolValue) {
                throw CLIError(message: String(
                    localized: "cli.ios.error.outputDirectoryRequired",
                    defaultValue: "--out must name an existing directory when capturing multiple Simulators"
                ))
            }
        }
        let captures = try targets.map { target -> [String: Any] in
            if all, let error = target["error"] as? String {
                return [
                    "surface_ref": target["surface_ref"] ?? NSNull(),
                    "error": error,
                ]
            }
            guard let simulatorID = target["simulator_id"] as? String else {
                if all {
                    return [
                        "surface_ref": target["surface_ref"] ?? NSNull(),
                        "error": target["error"] ?? missingIOSSimulatorIdentifier().message,
                    ]
                }
                throw missingIOSSimulatorIdentifier()
            }
            guard let surfaceRef = target["surface_ref"] as? String else {
                if all {
                    return [
                        "surface_ref": NSNull(),
                        "error": missingIOSSurfaceReference().message,
                    ]
                }
                throw missingIOSSurfaceReference()
            }
            let destination: URL
            if let outputURL, !all, targets.count == 1 {
                destination = outputURL
            } else {
                let directory = outputURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                let safeRef = surfaceRef.replacingOccurrences(of: ":", with: "-")
                destination = directory.appendingPathComponent("ios-\(safeRef).png")
            }
            if let batchDeadline,
               ProcessInfo.processInfo.systemUptime >= batchDeadline {
                return [
                    "simulator_id": simulatorID,
                    "surface_ref": surfaceRef,
                    "error": iosScreenshotBatchTimeoutMessage(),
                ]
            }
            let result = SimulatorOwnedCommandRunner.run(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl", "io", simulatorID, "screenshot", destination.path],
                currentDirectory: FileManager.default.currentDirectoryPath,
                timeout: batchDeadline.map {
                    max(1, min(30, $0 - ProcessInfo.processInfo.systemUptime))
                } ?? 30
            )
            guard result.status == 0 else {
                if all {
                    return [
                        "simulator_id": simulatorID,
                        "surface_ref": surfaceRef,
                        "error": result.standardError.trimmingCharacters(in: .whitespacesAndNewlines),
                    ]
                }
                throw CLIError(message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
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
                    print(simulatorTerminalText(path))
                } else if let error = capture["error"] as? String {
                    let surface = simulatorTerminalText(capture["surface_ref"] as? String ?? "?")
                    cliWriteStderr("\(surface): \(simulatorTerminalText(error))\n")
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
        surface: String?,
        client: SocketClient,
        windowOverride: String?,
        responseTimeout: TimeInterval? = nil
    ) throws -> [String: Any] {
        var params = try simulatorRoutingParams(
            surface: surface,
            client: client,
            windowOverride: windowOverride
        )
        if let responseTimeout {
            params["operation_timeout_seconds"] = min(550, max(0.1, responseTimeout - 6))
        }
        return try client.sendV2(
            method: "simulator.context",
            params: params,
            responseTimeout: responseTimeout ?? simulatorOperationDeadlines.clientTimeout(
                for: simulatorOperationDeadlines.selectDevice
            )
        )
    }

    private func iosScreenshotContextPayload(
        surface: String?,
        client: SocketClient,
        windowOverride: String?,
        responseTimeout: TimeInterval? = nil
    ) throws -> [String: Any] {
        let params = try simulatorRoutingParams(
            surface: surface,
            client: client,
            windowOverride: windowOverride
        )
        return try client.sendV2(
            method: "simulator.prepare_screenshot",
            params: params,
            responseTimeout: responseTimeout ?? simulatorOperationDeadlines.clientTimeout(
                for: simulatorOperationDeadlines.selectDevice
            )
        )
    }

    private func iosScreenshotBatchTimeoutMessage() -> String {
        String(
            localized: "cli.ios.error.screenshotBatchTimeout",
            defaultValue: "The iOS Simulator screenshot batch exceeded its 10-minute deadline"
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

    private func missingIOSSurfaceReference() -> CLIError {
        CLIError(message: String(
            localized: "cli.ios.error.missingSurfaceReference",
            defaultValue: "The selected iOS pane has no surface reference"
        ))
    }

    private func printIOSContext(_ payload: [String: Any]) {
        for key in [
            "simulator_id", "device_name", "runtime_id", "state", "orientation", "surface_ref",
        ] {
            if let value = payload[key], !(value is NSNull) {
                print("\(key)=\(simulatorTerminalText(String(describing: value)))")
            }
        }
    }

    private func printIOSTargets(_ targets: [[String: Any]]) {
        guard !targets.isEmpty else {
            print(String(localized: "cli.ios.output.noTargets", defaultValue: "No iOS Simulator panes"))
            return
        }
        for target in targets {
            print([
                simulatorTerminalText(target["surface_ref"] as? String ?? "?"),
                simulatorTerminalText(target["device_name"] as? String ?? "?"),
                simulatorTerminalText(target["simulator_id"] as? String ?? "?"),
                simulatorTerminalText(target["state"] as? String ?? "?"),
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
        var params = try simulatorRoutingParams(
            surface: parsed.surface,
            client: client,
            windowOverride: windowOverride
        )

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
            let text = try simulatorSourceValue(
                parsed,
                maximumBytes: Self.simulatorTextLimit
            )
            let deliveryTimeout = (try? SimulatorUSKeyboardTextEncoder().encode(text))?
                .completionTimeoutSeconds ?? 120
            params["text"] = text
            method = "simulator.type"
            responseTimeout = simulatorOperationDeadlines.clientTimeout(
                for: deliveryTimeout
                    + simulatorOperationDeadlines.textInputReadiness
            )
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

    private func simulatorRoutingParams(
        surface: String?,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        let window = try normalizeWindowHandle(windowOverride, client: client)
        let callerWorkspace = Self.callerWorkspaceForSurfaceHandle(
            surface,
            windowRaw: window
        )
        let workspace = try normalizeWorkspaceHandle(
            callerWorkspace,
            client: client,
            windowHandle: window
        )
        let normalizedSurface = try normalizeSurfaceHandle(
            surface,
            client: client,
            workspaceHandle: workspace,
            windowHandle: window
        )
        return try simulatorRoutingParams(
            normalizedSurface: normalizedSurface,
            window: window,
            workspace: workspace
        )
    }

    private func simulatorRoutingParams(
        normalizedSurface: String?,
        window: String?,
        workspace: String?
    ) throws -> [String: Any] {
        if window != nil || workspace != nil || normalizedSurface != nil {
            var params: [String: Any] = [:]
            if let window { params["window_id"] = window }
            if let workspace { params["workspace_id"] = workspace }
            if let normalizedSurface { params["surface_id"] = normalizedSurface }
            return params
        }

        let environment = ProcessInfo.processInfo.environment
        guard let workspaceID = environment["CMUX_WORKSPACE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceID.isEmpty else { return [:] }
        return ["workspace_id": workspaceID]
    }

}
