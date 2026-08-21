import Foundation

extension CMUXCLI {
    func runDumpCommandTree() throws {
        let data = Data(CmuxCommand._dumpHelp().utf8)
        let toolInfo = try JSONDecoder().decode(CommandTreeToolInfo.self, from: data)
        let entries = commandTreeEntries(from: toolInfo.command)
            .sorted { $0.path < $1.path }

        for entry in entries {
            print("command  \(entry.path)  aliases=\(entry.aliases)")
            for argument in entry.arguments.sorted(by: { $0.name < $1.name }) {
                print("  arg  \(argument.name)  kind=\(argument.kind)  completion=\(argument.completion)")
            }
        }
    }

    private func commandTreeEntries(from root: CommandTreeCommandInfo) -> [CommandTreeEntry] {
        root.subcommands
            .filter { $0.commandName != "help" }
            .flatMap { commandTreeEntries(from: $0, path: []) }
    }

    private func commandTreeEntries(
        from command: CommandTreeCommandInfo,
        path: [String]
    ) -> [CommandTreeEntry] {
        let path = path + [command.commandName]
        let entry = CommandTreeEntry(
            path: path.joined(separator: " "),
            aliases: command.aliases?.sorted().joined(separator: ",") ?? "-",
            arguments: command.arguments
                .filter { $0.preferredName?.rendered != "--help" }
                .map(CommandTreeArgumentEntry.init)
        )
        return [entry] + command.subcommands.flatMap { commandTreeEntries(from: $0, path: path) }
    }
}

private struct CommandTreeToolInfo: Decodable {
    let command: CommandTreeCommandInfo
}

private struct CommandTreeCommandInfo: Decodable {
    let commandName: String
    let aliases: [String]?
    let subcommands: [CommandTreeCommandInfo]
    let arguments: [CommandTreeArgumentInfo]

    private enum CodingKeys: String, CodingKey {
        case commandName
        case aliases
        case subcommands
        case arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commandName = try container.decode(String.self, forKey: .commandName)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases)
        subcommands = try container.decodeIfPresent([CommandTreeCommandInfo].self, forKey: .subcommands) ?? []
        arguments = try container.decodeIfPresent([CommandTreeArgumentInfo].self, forKey: .arguments) ?? []
    }
}

private struct CommandTreeArgumentInfo: Decodable {
    let kind: String
    let preferredName: CommandTreeArgumentName?
    let valueName: String?
    let completionKind: CommandTreeCompletionKind?
}

private struct CommandTreeArgumentName: Decodable {
    let kind: String
    let name: String

    var rendered: String {
        switch kind {
        case "long": "--\(name)"
        case "short", "longWithSingleDash": "-\(name)"
        default: name
        }
    }
}

private enum CommandTreeCompletionKind: Decodable {
    case list(values: [String])
    case file(extensions: [String])
    case directory
    case shellCommand(command: String)
    case custom
    case customAsync
    case customDeprecated

    var rendered: String {
        switch self {
        case .list(let values): "list(\(values.sorted().joined(separator: ",")))"
        case .file(let extensions): "file(\(extensions.sorted().joined(separator: ",")))"
        case .directory: "directory"
        case .shellCommand(let command): "shell-command(\(command))"
        case .custom: "custom"
        case .customAsync: "custom-async"
        case .customDeprecated: "custom-deprecated"
        }
    }
}

private struct CommandTreeEntry {
    let path: String
    let aliases: String
    let arguments: [CommandTreeArgumentEntry]
}

private struct CommandTreeArgumentEntry {
    let name: String
    let kind: String
    let completion: String

    init(_ argument: CommandTreeArgumentInfo) {
        name = argument.preferredName?.rendered ?? argument.valueName ?? "-"
        kind = argument.kind == "positional" ? "argument" : argument.kind
        completion = argument.completionKind?.rendered ?? "-"
    }
}
