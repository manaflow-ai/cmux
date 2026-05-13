import Foundation

nonisolated struct AgentFastPathParsedArgs: Sendable {
    let flags: Set<String>
    let options: [String: String]
    let positionals: [String]
}

extension CMUXCLI {
    func agentFastPathParseArgs(
        _ args: [String],
        commandName: String,
        flags allowedFlags: Set<String> = [],
        valueOptions: Set<String> = []
    ) throws -> AgentFastPathParsedArgs {
        var flags = Set<String>()
        var options: [String: String] = [:]
        var positionals: [String] = []
        var index = 0
        var pastTerminator = false

        while index < args.count {
            let arg = args[index]

            if pastTerminator {
                positionals.append(arg)
                index += 1
                continue
            }

            if arg == "--" {
                pastTerminator = true
                index += 1
                continue
            }

            if valueOptions.contains(arg) {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw CLIError(message: "\(commandName): \(arg) requires a value")
                }
                options[arg] = args[valueIndex]
                index += 2
                continue
            }

            if allowedFlags.contains(arg) {
                flags.insert(arg)
                index += 1
                continue
            }

            if arg.hasPrefix("-") {
                throw CLIError(message: "\(commandName): unknown option \(arg)")
            }

            positionals.append(arg)
            index += 1
        }

        return AgentFastPathParsedArgs(
            flags: flags,
            options: options,
            positionals: positionals
        )
    }
}
