import Foundation

extension CMUXCLI {
    func printHooksAgentList(arguments: [String]) {
        let agents = Self.agentDefs.map { def in
            [
                "aliases": def.aliases.sorted(),
                "binaryName": def.binaryName,
                "configDir": def.configDir,
                "configFile": def.configFile,
                "displayName": def.displayName,
                "installCommand": "cmux hooks \(def.name) install",
                "name": def.name,
                "statusKey": def.statusKey,
            ] as [String: Any]
        }

        if arguments.contains("--json") || ProcessInfo.processInfo.arguments.contains("--json") {
            print(jsonString(["agents": agents]))
            return
        }

        for agent in agents {
            print("\(agent["name"] ?? "")\t\(agent["displayName"] ?? "")")
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

    static func hooksSetupPositionalAgentFilter(from args: [String]) throws -> String? {
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
}
