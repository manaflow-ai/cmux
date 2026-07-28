import Foundation

extension CMUXCLI {
    private struct AgentWaitOptions {
        var surface: String?
        var until: String?
        var timeoutMilliseconds: Int64?
    }

    func runAgentWaitCommand(
        commandArgs: [String],
        client: SocketClient,
        windowHandle: String?,
        jsonOutput: Bool
    ) throws {
        let options = try parseAgentWaitOptions(commandArgs)
        guard let rawSurface = options.surface else {
            throw CLIError(
                message: String(
                    localized: "cli.wait.error.surfaceRequired",
                    defaultValue: "wait requires --surface <id|ref|index>"
                ),
                exitCode: 2
            )
        }
        guard let until = options.until else {
            throw CLIError(
                message: String(
                    localized: "cli.wait.error.untilRequired",
                    defaultValue: "wait requires --until <idle|needs-input|exit>"
                ),
                exitCode: 2
            )
        }

        let workspaceHandle = Self.callerWorkspaceForSurfaceHandle(
            rawSurface,
            windowRaw: windowHandle
        )
        guard let surface = try normalizeSurfaceHandle(
            rawSurface,
            client: client,
            workspaceHandle: workspaceHandle,
            windowHandle: windowHandle
        ) else {
            throw CLIError(
                message: String(
                    localized: "cli.wait.error.surfaceRequired",
                    defaultValue: "wait requires --surface <id|ref|index>"
                ),
                exitCode: 2
            )
        }

        var params: [String: Any] = [
            "surface_id": surface,
            "until": until,
        ]
        if let timeoutMilliseconds = options.timeoutMilliseconds {
            params["timeout_ms"] = NSNumber(value: timeoutMilliseconds)
        }
        let responseTimeout = options.timeoutMilliseconds.map {
            max(15, Double($0) / 1_000 + 5)
        } ?? 365 * 24 * 60 * 60
        let result = try client.sendV2(
            method: "agent.wait",
            params: params,
            responseTimeout: responseTimeout
        )

        if jsonOutput {
            print(jsonString(result))
        }
        guard let status = result["status"] as? String else {
            throw CLIError(
                message: String(
                    localized: "cli.wait.error.invalidResponse",
                    defaultValue: "agent.wait returned an invalid response"
                )
            )
        }
        switch status {
        case "satisfied":
            return
        case "timed_out":
            throw CLIError(
                message: String(
                    localized: "cli.wait.error.timedOut",
                    defaultValue: "Timed out waiting for the requested agent state"
                ),
                exitCode: 124,
                shouldPrint: !jsonOutput
            )
        case "surface_closed":
            throw CLIError(
                message: String(
                    localized: "cli.wait.error.surfaceClosed",
                    defaultValue: "Surface closed before the requested agent state was reached"
                ),
                exitCode: 3,
                shouldPrint: !jsonOutput
            )
        default:
            throw CLIError(
                message: String(
                    localized: "cli.wait.error.invalidResponse",
                    defaultValue: "agent.wait returned an invalid response"
                )
            )
        }
    }

    private func parseAgentWaitOptions(_ args: [String]) throws -> AgentWaitOptions {
        var options = AgentWaitOptions()
        var index = 0
        while index < args.count {
            let argument = args[index]
            func requireValue() throws -> String {
                guard index + 1 < args.count else {
                    throw CLIError(
                        message: String.localizedStringWithFormat(
                            String(
                                localized: "cli.wait.error.missingValue",
                                defaultValue: "%@ requires a value"
                            ),
                            argument
                        ),
                        exitCode: 2
                    )
                }
                index += 1
                return args[index]
            }

            switch argument {
            case "--surface":
                options.surface = try requireValue()
            case "--until":
                let value = try requireValue()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .replacing("_", with: "-")
                guard ["idle", "needs-input", "exit"].contains(value) else {
                    throw CLIError(
                        message: String(
                            localized: "cli.wait.error.invalidUntil",
                            defaultValue: "wait --until must be idle, needs-input, or exit"
                        ),
                        exitCode: 2
                    )
                }
                options.until = value
            case "--timeout", "--timeout-ms":
                let rawValue = try requireValue()
                guard let value = Int64(rawValue), value >= 0 else {
                    throw CLIError(
                        message: String(
                            localized: "cli.wait.error.invalidTimeout",
                            defaultValue: "wait --timeout must be a non-negative integer in milliseconds"
                        ),
                        exitCode: 2
                    )
                }
                options.timeoutMilliseconds = value
            default:
                throw CLIError(
                    message: String.localizedStringWithFormat(
                        String(
                            localized: "cli.wait.error.unknownOption",
                            defaultValue: "Unknown wait option: %@"
                        ),
                        argument
                    ),
                    exitCode: 2
                )
            }
            index += 1
        }
        return options
    }
}
