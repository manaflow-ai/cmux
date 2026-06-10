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


// MARK: - Surface and surface-resume commands
extension CMUXCLI {
    func runSurfaceCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: "surface requires a subcommand. Try: cmux surface resume show --json")
        }
        switch subcommand {
        case "resume":
            try runSurfaceResumeCommand(
                commandArgs: Array(commandArgs.dropFirst()),
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )
        default:
            throw CLIError(message: "Unsupported surface subcommand: \(subcommand)")
        }
    }

    func runSurfaceResumeCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "show"
        let rest = commandArgs.first == nil ? [] : Array(commandArgs.dropFirst())
        switch subcommand {
        case "set":
            try validateSurfaceResumeValueOptions(
                rest,
                optionNames: Self.surfaceResumeSetValueOptions,
                context: "surface resume set"
            )
            let target = try surfaceResumeTarget(rest, client: client, windowOverride: windowOverride)
            var params = target.params
            let splitRemaining = splitAtArgumentTerminator(target.remaining)
            let (name, rem1) = parseOption(splitRemaining.options, name: "--name")
            let (kind, rem2) = parseOption(rem1, name: "--kind")
            let (checkpoint, rem3) = parseOption(rem2, name: "--checkpoint")
            let (checkpointID, rem4) = parseOption(rem3, name: "--checkpoint-id")
            let (source, rem5) = parseOption(rem4, name: "--source")
            let (cwd, rem6) = parseOption(rem5, name: "--cwd")
            let (shellCommand, rem7) = parseOption(rem6, name: "--shell")

            if let name { params["name"] = name }
            if let kind { params["kind"] = kind }
            if let checkpoint = checkpointID ?? checkpoint { params["checkpoint_id"] = checkpoint }
            params["source"] = source ?? "cli"
            params["cwd"] = cwd ?? ProcessInfo.processInfo.environment["PWD"] ?? FileManager.default.currentDirectoryPath

            let commandText: String
            if let shellCommand {
                if let unexpected = (rem7 + (splitRemaining.argv ?? [])).first {
                    throw CLIError(message: "surface resume set: unexpected argument '\(unexpected)' after --shell. Quote the full shell command or use -- <argv...>")
                }
                commandText = shellCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                if splitRemaining.argv != nil, let unexpected = rem7.first {
                    throw CLIError(message: "surface resume set: unexpected argument '\(unexpected)' before --")
                }
                let argv = splitRemaining.argv ?? rem7
                guard !argv.isEmpty else {
                    throw CLIError(message: "surface resume set requires --shell <command> or -- <argv...>")
                }
                commandText = argv.map(cliShellQuote).joined(separator: " ")
            }
            guard !commandText.isEmpty else {
                throw CLIError(message: "surface resume set requires a non-empty command")
            }
            params["command"] = commandText

            let payload = try client.sendV2(method: "surface.resume.set", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "show", "get":
            try validateSurfaceResumeValueOptions(
                rest,
                optionNames: Self.surfaceResumeTargetValueOptions,
                context: "surface resume \(subcommand)"
            )
            let params = try surfaceResumeTarget(rest, client: client, windowOverride: windowOverride).params
            let payload = try client.sendV2(method: "surface.resume.get", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else if let binding = payload["resume_binding"] as? [String: Any],
                      let command = binding["command"] as? String,
                      !command.isEmpty {
                print(command)
            } else {
                print("No resume binding")
            }

        case "clear":
            try validateSurfaceResumeValueOptions(
                rest,
                optionNames: Self.surfaceResumeClearValueOptions,
                context: "surface resume clear"
            )
            let target = try surfaceResumeTarget(rest, client: client, windowOverride: windowOverride)
            var params = target.params
            let (checkpoint, rem1) = parseOption(target.remaining, name: "--checkpoint")
            let (checkpointID, rem2) = parseOption(rem1, name: "--checkpoint-id")
            let (source, remaining) = parseOption(rem2, name: "--source")
            if let unexpected = remaining.first {
                throw CLIError(message: "surface resume clear: unexpected argument '\(unexpected)'")
            }
            if let checkpoint = checkpointID ?? checkpoint { params["checkpoint_id"] = checkpoint }
            if let source { params["source"] = source }
            let payload = try client.sendV2(method: "surface.resume.clear", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        default:
            throw CLIError(message: "Unsupported surface resume subcommand: \(subcommand)")
        }
    }

    func validateSurfaceResumeCommandValueOptionsBeforeSocket(
        command: String,
        commandArgs: [String]
    ) throws {
        if command == "surface" {
            guard commandArgs.first?.lowercased() == "resume" else { return }
            try validateSurfaceResumeCommandValueOptions(Array(commandArgs.dropFirst()))
            return
        }
        if command == "surface-resume" {
            try validateSurfaceResumeCommandValueOptions(commandArgs)
        }
    }

    private func validateSurfaceResumeCommandValueOptions(_ commandArgs: [String]) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "show"
        let rest = commandArgs.first == nil ? [] : Array(commandArgs.dropFirst())
        switch subcommand {
        case "set":
            try validateSurfaceResumeValueOptions(
                rest,
                optionNames: Self.surfaceResumeSetValueOptions,
                context: "surface resume set"
            )
            try validateSurfaceResumeSetCommandTokensBeforeSocket(rest)
        case "show", "get":
            try validateSurfaceResumeValueOptions(
                rest,
                optionNames: Self.surfaceResumeTargetValueOptions,
                context: "surface resume \(subcommand)"
            )
        case "clear":
            try validateSurfaceResumeValueOptions(
                rest,
                optionNames: Self.surfaceResumeClearValueOptions,
                context: "surface resume clear"
            )
        default:
            return
        }
    }

    private func validateSurfaceResumeSetCommandTokensBeforeSocket(_ args: [String]) throws {
        let splitArgs = splitAtArgumentTerminator(args)
        let (_, rem1) = parseOption(splitArgs.options, name: "--workspace")
        let (_, rem2) = parseOption(rem1, name: "--surface")
        let (_, rem3) = parseOption(rem2, name: "--window")
        let (_, rem4) = parseOption(rem3, name: "--name")
        let (_, rem5) = parseOption(rem4, name: "--kind")
        let (_, rem6) = parseOption(rem5, name: "--checkpoint")
        let (_, rem7) = parseOption(rem6, name: "--checkpoint-id")
        let (_, rem8) = parseOption(rem7, name: "--source")
        let (_, rem9) = parseOption(rem8, name: "--cwd")
        let (shellCommand, remaining) = parseOption(rem9, name: "--shell")

        if shellCommand != nil, let unexpected = (remaining + (splitArgs.argv ?? [])).first {
            throw CLIError(message: "surface resume set: unexpected argument '\(unexpected)' after --shell. Quote the full shell command or use -- <argv...>")
        }
        if splitArgs.argv != nil, let unexpected = remaining.first {
            throw CLIError(message: "surface resume set: unexpected argument '\(unexpected)' before --")
        }
    }

    private static let surfaceResumeTargetValueOptions: Set<String> = ["--workspace", "--surface", "--window"]
    private static let surfaceResumeSetValueOptions: Set<String> = surfaceResumeTargetValueOptions.union([
        "--name", "--kind", "--checkpoint", "--checkpoint-id", "--source", "--cwd", "--shell",
    ])
    private static let surfaceResumeClearValueOptions: Set<String> = surfaceResumeTargetValueOptions.union([
        "--checkpoint", "--checkpoint-id", "--source",
    ])

    private func validateSurfaceResumeValueOptions(
        _ args: [String],
        optionNames: Set<String>,
        context: String
    ) throws {
        var pastTerminator = false
        for (index, arg) in args.enumerated() {
            if pastTerminator {
                continue
            }
            if arg == "--" {
                pastTerminator = true
                continue
            }
            guard optionNames.contains(arg) else { continue }
            guard index + 1 < args.count else {
                throw CLIError(message: "\(context): \(arg) requires a value")
            }
            let value = args[index + 1]
            guard value != "--",
                  !optionNames.contains(value),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError(message: "\(context): \(arg) requires a value")
            }
        }
    }

    private struct SurfaceResumeTarget {
        var params: [String: Any]
        var remaining: [String]
    }

    private func splitAtArgumentTerminator(_ args: [String]) -> (options: [String], argv: [String]?) {
        guard let delimiterIndex = args.firstIndex(of: "--") else {
            return (args, nil)
        }
        let argvStart = args.index(after: delimiterIndex)
        return (Array(args[..<delimiterIndex]), Array(args[argvStart...]))
    }

    private func surfaceResumeTarget(
        _ args: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> SurfaceResumeTarget {
        let splitArgs = splitAtArgumentTerminator(args)
        let (workspaceOpt, rem1) = parseOption(splitArgs.options, name: "--workspace")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (windowOpt, remaining) = parseOption(rem2, name: "--window")
        let windowRaw = windowOpt ?? windowOverride
        let env = ProcessInfo.processInfo.environment
        let usesImplicitSurface = surfaceOpt == nil
            && windowRaw == nil
            && env["CMUX_SURFACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let shouldUseEnvWorkspace = surfaceOpt == nil
            && !usesImplicitSurface
            && windowRaw == nil
        let workspaceRaw = workspaceOpt ?? (shouldUseEnvWorkspace ? env["CMUX_WORKSPACE_ID"] : nil)
        let surfaceRaw = surfaceOpt ?? (workspaceOpt == nil && windowRaw == nil ? env["CMUX_SURFACE_ID"] : nil)
        var params: [String: Any] = [:]
        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        if let windowHandle { params["window_id"] = windowHandle }
        let workspaceId = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)
        if let workspaceId { params["workspace_id"] = workspaceId }
        let surfaceId = try normalizeSurfaceHandle(
            surfaceRaw,
            client: client,
            workspaceHandle: workspaceId,
            windowHandle: windowHandle
        )
        if let surfaceId { params["surface_id"] = surfaceId }
        let remainingWithArgv = remaining + (splitArgs.argv.map { ["--"] + $0 } ?? [])
        return SurfaceResumeTarget(params: params, remaining: remainingWithArgv)
    }

    func cliShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}
