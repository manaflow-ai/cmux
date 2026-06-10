import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Main command dispatch
extension CMUXCLI {
    func run() throws {
        let processEnv = ProcessInfo.processInfo.environment
        let cliBundleIdentifier = CLISocketPathResolver.currentAppBundleIdentifier()
        var explicitSocketPath: String? = nil
        var jsonOutput = false
        var idFormatArg: String? = nil
        var windowId: String? = nil
        var socketPasswordArg: String? = nil

        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--socket" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--socket requires a path")
                }
                explicitSocketPath = args[index + 1]
                index += 2
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                index += 1
                continue
            }
            if arg == "--id-format" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--id-format requires a value (refs|uuids|both)")
                }
                idFormatArg = args[index + 1]
                index += 2
                continue
            }
            if arg == "--window" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--window requires a window id")
                }
                windowId = args[index + 1]
                index += 2
                continue
            }
            if arg == "--password" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--password requires a value")
                }
                socketPasswordArg = args[index + 1]
                index += 2
                continue
            }
            if arg == "-v" || arg == "--version" {
                print(versionSummary())
                return
            }
            if arg == "-h" || arg == "--help" {
                print(usage())
                return
            }
            break
        }

        guard index < args.count else {
            throw CLIError(
                message: "Missing command. Usage: cmux <path>|<command> [options]. Run 'cmux --help' for the full command list.",
                exitCode: 2
            )
        }

        let command = args[index]
        let presentationOptions = try parsePresentationOptions(Array(args[(index + 1)...]))
        if presentationOptions.jsonOutput {
            jsonOutput = true
        }
        if let parsedIDFormat = presentationOptions.idFormat {
            idFormatArg = parsedIDFormat
        }
        let commandArgs = presentationOptions.remaining

        if try runPreSocketEarlyCommand(
            command: command,
            commandArgs: commandArgs,
            jsonOutput: jsonOutput,
            socketPasswordArg: socketPasswordArg,
            explicitSocketPath: explicitSocketPath,
            cliBundleIdentifier: cliBundleIdentifier,
            processEnv: processEnv
        ) {
            return
        }

        let envSocketPath = explicitSocketPath == nil
            ? try CLISocketEnvironment.socketPath(in: processEnv)
            : CLISocketEnvironment.socketPathForTelemetry(in: processEnv)
        let socketPath = explicitSocketPath ?? envSocketPath ?? CLISocketPathResolver.defaultSocketPath(
            bundleIdentifier: cliBundleIdentifier,
            environment: processEnv
        )
        let socketPathSource: CLISocketPathSource
        if explicitSocketPath != nil {
            socketPathSource = .explicitFlag
        } else if let envSocketPath {
            socketPathSource = CLISocketPathResolver.isImplicitDefaultPath(
                envSocketPath,
                bundleIdentifier: cliBundleIdentifier,
                environment: processEnv
            ) ? .implicitDefault : .environment
        } else {
            socketPathSource = .implicitDefault
        }
        let cliTelemetry = CLISocketSentryTelemetry(
            command: command,
            commandArgs: commandArgs,
            socketPath: socketPath,
            processEnv: processEnv
        )
        let resolvedSocketPath = CLISocketPathResolver.resolve(
            requestedPath: socketPath,
            source: socketPathSource,
            environment: processEnv,
            bundleIdentifier: cliBundleIdentifier
        )

        if try runPreSocketResolvedCommand(
            command: command,
            commandArgs: commandArgs,
            jsonOutput: jsonOutput,
            idFormatArg: idFormatArg,
            socketPasswordArg: socketPasswordArg,
            resolvedSocketPath: resolvedSocketPath,
            cliTelemetry: cliTelemetry,
            processEnv: processEnv
        ) {
            return
        }

        let client = SocketClient(path: resolvedSocketPath)
        if resolvedSocketPath != socketPath {
            cliTelemetry.breadcrumb(
                "socket.path.autodiscovered",
                data: [
                    "requested_path": socketPath,
                    "resolved_path": resolvedSocketPath
                ]
            )
        }
        cliTelemetry.breadcrumb(
            "socket.connect.attempt",
            data: [
                "command": command,
                "path": resolvedSocketPath
            ]
        )
        do {
            try client.connect()
            cliTelemetry.breadcrumb("socket.connect.success", data: ["path": resolvedSocketPath])
        } catch {
            cliTelemetry.breadcrumb("socket.connect.failure", data: ["path": resolvedSocketPath])
            cliTelemetry.captureError(stage: "socket_connect", error: error)
            throw error
        }
        defer { client.close() }

        try authenticateClientIfNeeded(
            client,
            explicitPassword: socketPasswordArg,
            socketPath: resolvedSocketPath
        )

        let idFormat = try resolvedIDFormat(jsonOutput: jsonOutput, raw: idFormatArg)
        // Most CLI --window routing focuses first so commands without an
        // explicit window_id still target the selected window.
        if let windowId, Self.shouldFocusWindowBeforeDispatch(command: command, commandArgs: commandArgs) {
            do {
                let normalizedWindow = try normalizeWindowHandle(windowId, client: client) ?? windowId
                _ = try client.sendV2(method: "window.focus", params: ["window_id": normalizedWindow])
            } catch {
                captureSocketTransportError(telemetry: cliTelemetry, stage: "socket_command_window_focus", error: error, client: client)
                throw error
            }
        }

        let capturesSocketErrorsInsideCommand = ["claude-hook", "codex-hook", "feed-hook", "hooks"].contains(command) // Backwards compatibility aliases stay hidden from help.
        do {
            var handled = try runCoreClientCommand(
                command: command,
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                idFormatArg: idFormatArg,
                windowId: windowId
            )
            if !handled {
                handled = try runWindowWorkspaceCommand(
                    command: command,
                    commandArgs: commandArgs,
                    client: client,
                    jsonOutput: jsonOutput,
                    idFormat: idFormat,
                    windowId: windowId
                )
            }
            if !handled {
                handled = try runPaneSurfaceCommand(
                    command: command,
                    commandArgs: commandArgs,
                    client: client,
                    jsonOutput: jsonOutput,
                    idFormat: idFormat,
                    windowId: windowId
                )
            }
            if !handled {
                handled = try runNotificationSidebarCommand(
                    command: command,
                    commandArgs: commandArgs,
                    client: client,
                    jsonOutput: jsonOutput,
                    idFormat: idFormat,
                    windowId: windowId
                )
            }
            if !handled {
                handled = try runAgentHooksMiscCommand(
                    command: command,
                    commandArgs: commandArgs,
                    client: client,
                    jsonOutput: jsonOutput,
                    idFormat: idFormat,
                    windowId: windowId,
                    socketPasswordArg: socketPasswordArg,
                    cliTelemetry: cliTelemetry
                )
            }
            if !handled {
                print(usage())
                throw CLIError(message: "Unknown command: \(command)")
            }
        } catch {
            if !capturesSocketErrorsInsideCommand {
                captureSocketTransportError(telemetry: cliTelemetry, stage: "socket_command", error: error, client: client)
            }
            throw error
        }
    }
}
