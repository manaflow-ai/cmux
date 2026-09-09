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
            let option: String
            let inlineValue: String?
            if let equalsIndex = argument.firstIndex(of: "=") {
                option = String(argument[..<equalsIndex])
                inlineValue = String(argument[argument.index(after: equalsIndex)...])
            } else {
                option = argument
                inlineValue = nil
            }

            func requireValue() throws -> String {
                if let inlineValue {
                    return inlineValue
                }
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

            switch option {
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

    /// Extracts the optional atomic wait flags from `cmux send` while leaving
    /// ordinary send arguments untouched when `--wait-until` is absent.
    func parseSendWaitOptions(
        _ args: [String]
    ) throws -> (until: String?, timeoutMilliseconds: Int64?, remaining: [String]) {
        let optionTokens = Array(args.prefix { $0 != "--" })
        let hasWaitUntil = optionTokens.contains {
            $0 == "--wait-until" || $0.hasPrefix("--wait-until=")
        }
        guard hasWaitUntil else {
            return (nil, nil, args)
        }

        let (rawUntil, afterUntil) = parseOption(args, name: "--wait-until")
        guard let rawUntil else {
            throw CLIError(
                message: String(
                    localized: "cli.wait.error.missingValue",
                    defaultValue: "--wait-until requires a value"
                ),
                exitCode: 2
            )
        }
        let normalizedUntil = rawUntil
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacing("_", with: "-")
        guard ["idle", "needs-input", "exit"].contains(normalizedUntil) else {
            throw CLIError(
                message: String(
                    localized: "cli.wait.error.invalidUntil",
                    defaultValue: "--wait-until must be idle, needs-input, or exit"
                ),
                exitCode: 2
            )
        }

        let (rawTimeout, afterTimeout) = parseOption(afterUntil, name: "--timeout")
        let (rawTimeoutMS, remaining) = parseOption(afterTimeout, name: "--timeout-ms")
        let timeoutTokens = Array(afterUntil.prefix { $0 != "--" })
        let hasTimeout = timeoutTokens.contains {
            $0 == "--timeout" || $0.hasPrefix("--timeout=")
        }
        let timeoutMSTokens = Array(afterTimeout.prefix { $0 != "--" })
        let hasTimeoutMS = timeoutMSTokens.contains {
            $0 == "--timeout-ms" || $0.hasPrefix("--timeout-ms=")
        }
        guard rawTimeout == nil || rawTimeoutMS == nil else {
            throw CLIError(
                message: String(
                    localized: "cli.wait.error.invalidTimeout",
                    defaultValue: "Use only one of --timeout or --timeout-ms"
                ),
                exitCode: 2
            )
        }
        let timeoutRaw = rawTimeout ?? rawTimeoutMS
        let timeoutMilliseconds: Int64?
        if hasTimeout || hasTimeoutMS {
            guard let timeoutRaw else {
                throw CLIError(
                    message: String(
                        localized: "cli.wait.error.invalidTimeout",
                        defaultValue: "--timeout must be followed by a non-negative integer in milliseconds"
                    ),
                    exitCode: 2
                )
            }
            guard let value = Int64(timeoutRaw), value >= 0 else {
                throw CLIError(
                    message: String(
                        localized: "cli.wait.error.invalidTimeout",
                        defaultValue: "--timeout must be a non-negative integer in milliseconds"
                    ),
                    exitCode: 2
                )
            }
            timeoutMilliseconds = value
        } else {
            timeoutMilliseconds = nil
        }

        return (normalizedUntil, timeoutMilliseconds, remaining)
    }
}
