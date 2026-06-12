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


// MARK: - hooks namespace commands
extension CMUXCLI {
    // MARK: - Hooks namespace

    func runHooksNoSocketCommand(commandArgs: [String]) throws -> Bool {
        guard let first = commandArgs.first?.lowercased() else {
            print(subcommandUsage("hooks") ?? "Usage: cmux hooks <setup|uninstall|agent>")
            return true
        }

        switch first {
        case "help", "--help", "-h":
            print(subcommandUsage("hooks") ?? "Usage: cmux hooks <setup|uninstall|agent>")
            return true

        case "setup":
            try runSetupHooks(
                uninstall: false,
                positionalAgentFilter: try Self.hooksSetupPositionalAgentFilter(from: Array(commandArgs.dropFirst()))
            )
            return true

        case "uninstall":
            try runSetupHooks(
                uninstall: true,
                positionalAgentFilter: try Self.hooksSetupPositionalAgentFilter(from: Array(commandArgs.dropFirst()))
            )
            return true

        default:
            guard let def = Self.agentDef(named: first) else {
                if first == "feed" || first == "claude" {
                    return false
                }
                throw CLIError(message: "Unknown hooks target: \(first)")
            }

            let rest = Array(commandArgs.dropFirst())
            guard let action = rest.first?.lowercased() else {
                print(subcommandUsage("hooks") ?? "Usage: cmux hooks <setup|uninstall|agent>")
                return true
            }
            let actionArgs = Array(rest.dropFirst())
            switch action {
            case "install":
                try installHooksForAgent(def, arguments: actionArgs)
                return true
            case "uninstall":
                try uninstallHooksForAgent(def, arguments: actionArgs)
                return true
            case "install-hooks", "uninstall-hooks", "remove":
                throw CLIError(message: "Unknown hooks action: \(action). Use install or uninstall.")
            default:
                return false
            }
        }
    }

    static func hooksCommandNeedsCmuxTarget(_ commandArgs: [String]) -> Bool {
        guard let first = commandArgs.first?.lowercased() else { return false }
        if first == "feed" || first == "claude" { return true }
        guard let def = Self.agentDef(named: first) else { return false }
        let action = commandArgs.dropFirst().first?.lowercased()
        if def.name == "grok" {
            return false
        }
        return action != "install" && action != "uninstall"
    }

    func installHooksForAgent(_ def: AgentHookDef, arguments: [String]) throws {
        if def.name == "opencode" {
            let projectLocal = arguments.contains("--project")
            if projectLocal {
                // Project-local OpenCode install manages only the plugin file.
                try installOpenCodePlugin(projectLocal: true)
                return
            }
            try installAgentHooks(def)
            try installOpenCodePlugin(projectLocal: false)
            return
        }
        try installAgentHooks(def)
    }

    func uninstallHooksForAgent(_ def: AgentHookDef, arguments: [String]) throws {
        if def.name == "opencode" {
            let projectLocal = arguments.contains("--project")
            if projectLocal {
                try uninstallOpenCodePlugin(projectLocal: true)
                return
            }
            try uninstallAgentHooks(def)
            try uninstallOpenCodePlugin(projectLocal: false)
            return
        }
        try uninstallAgentHooks(def)
    }

    func runHooksSocketCommand(
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        socketPassword: String? = nil
    ) throws {
        guard let first = commandArgs.first?.lowercased() else {
            throw CLIError(message: "Usage: cmux hooks <setup|uninstall|feed|claude|agent>")
        }
        let rest = Array(commandArgs.dropFirst())

        switch first {
        case "setup", "install", "uninstall":
            throw CLIError(message: "hooks \(first) must be handled before socket dispatch")

        case "feed":
            telemetry.breadcrumb("hooks.feed.dispatch")
            do {
                try runFeedHook(commandArgs: rest, client: client, telemetry: telemetry)
                telemetry.breadcrumb("hooks.feed.completed")
            } catch {
                telemetry.breadcrumb("hooks.feed.failure")
                captureSocketTransportError(telemetry: telemetry, stage: "hooks_feed_dispatch", error: error, client: client)
                throw error
            }

        case "claude":
            telemetry.breadcrumb("hooks.claude.dispatch")
            do {
                try runClaudeHook(commandArgs: rest, client: client, telemetry: telemetry, socketPassword: socketPassword)
                telemetry.breadcrumb("hooks.claude.completed")
            } catch {
                telemetry.breadcrumb("hooks.claude.failure")
                captureSocketTransportError(telemetry: telemetry, stage: "hooks_claude_dispatch", error: error, client: client)
                throw error
            }

        default:
            guard let def = Self.agentDef(named: first) else {
                throw CLIError(message: "Unknown hooks target: \(first)")
            }
            telemetry.breadcrumb("hooks.\(def.name).dispatch")
            do {
                try runGenericAgentHook(def: def, commandArgs: rest, client: client, telemetry: telemetry, socketPassword: socketPassword)
                telemetry.breadcrumb("hooks.\(def.name).completed")
            } catch {
                telemetry.breadcrumb("hooks.\(def.name).failure")
                captureSocketTransportError(telemetry: telemetry, stage: "hooks_\(def.name)_dispatch", error: error, client: client)
                throw error
            }
        }
    }

    private static func hooksSetupPositionalAgentFilter(from args: [String]) throws -> String? {
        var skipNext = false
        var positionalAgent: String?
        for arg in args {
            if skipNext {
                skipNext = false
                continue
            }
            switch arg {
            case "--agent":
                skipNext = true
            case "--yes", "-y", "--uninstall":
                continue
            default:
                if !arg.hasPrefix("-") {
                    if positionalAgent != nil {
                        throw CLIError(message: "Too many hooks targets: specify at most one positional agent")
                    }
                    positionalAgent = arg
                }
            }
        }
        return positionalAgent
    }

    func runSetupHooks(uninstall: Bool = false, positionalAgentFilter: String? = nil) throws {
        let args = ProcessInfo.processInfo.arguments
        let flagAgentFilter = optionValue(args, name: "--agent")
        if let flagAgentFilter, let positionalAgentFilter {
            guard let flagDef = Self.agentDef(named: flagAgentFilter) else {
                throw CLIError(message: "Unknown hooks target: \(flagAgentFilter)")
            }
            guard let positionalDef = Self.agentDef(named: positionalAgentFilter) else {
                throw CLIError(message: "Unknown hooks target: \(positionalAgentFilter)")
            }
            if flagDef.name != positionalDef.name {
                throw CLIError(message: "Conflicting hooks target: use either --agent or a positional target, not both")
            }
        }
        let agentFilter = flagAgentFilter ?? positionalAgentFilter
        let agentFilterDef: AgentHookDef?
        if let agentFilter {
            guard let def = Self.agentDef(named: agentFilter) else {
                throw CLIError(message: "Unknown hooks target: \(agentFilter)")
            }
            agentFilterDef = def
        } else {
            agentFilterDef = nil
        }
        let isUninstall = uninstall || args.contains("--uninstall")
        let fm = FileManager.default
        let verb = isUninstall ? "uninstalling" : "installing"

        print("cmux hooks \(isUninstall ? "uninstall" : "setup"): \(verb) agent hooks")
        if !isUninstall {
            print("  (Claude Code hooks are injected automatically via the claude wrapper)")
        }
        print("")

        var count = 0
        var skipped = 0
        var skippedNoBinary: [String] = []

        for def in Self.agentDefs {
            if let agentFilterDef, agentFilterDef.name != def.name { continue }
            let configDir = def.resolvedConfigDir()
            let canUseMissingConfigDir = def.createConfigDirIfMissing
                || def.name == "opencode"
                || def.name == "pi"
                || def.name == "amp"
                || (!isUninstall && def.name == "rovodev")
            if !canUseMissingConfigDir, !fm.fileExists(atPath: configDir) {
                print("  \(def.name): skipped (config dir not found)")
                skipped += 1
                continue
            }
            // On install, also skip agents whose binary isn't on PATH.
            // On uninstall, always proceed so stale configs can be
            // cleaned up regardless of whether the binary still exists.
            if !isUninstall && !Self.isBinaryOnPath(def.binaryName) {
                print("  \(def.name): skipped (binary not found on PATH)")
                skipped += 1
                skippedNoBinary.append(def.name)
                continue
            }
            print("  \(def.name):")
            if isUninstall {
                try uninstallHooksForAgent(def, arguments: [])
            } else {
                try installHooksForAgent(def, arguments: [])
            }
            count += 1
            print("")
        }

        print("Done: \(count) \(isUninstall ? "uninstalled" : "installed"), \(skipped) skipped")
        if !skippedNoBinary.isEmpty {
            print("  skipped \(skippedNoBinary.count) agents (not found on PATH): \(skippedNoBinary.joined(separator: ", "))")
        }
    }

}
