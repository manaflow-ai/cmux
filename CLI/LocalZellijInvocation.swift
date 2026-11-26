import Foundation

struct LocalZellijInvocation {
    enum Action: String {
        case start
        case attach
        case list
        case status
        case close
    }

    let action: Action
    let name: String?
    let id: UUID?
    let cwd: String?
    let command: String?
    var attachRequest: LocalSessionAttachRequest
    let detached: Bool
    let headless: Bool

    var canRunWithoutCmux: Bool {
        switch action {
        case .list, .status, .close:
            return true
        case .start:
            return detached || headless
        case .attach:
            return headless
        }
    }

    static func parse(_ arguments: [String]) throws -> LocalZellijInvocation {
        guard let actionToken = arguments.first?.lowercased() else {
            throw CLIError(message: usage)
        }
        let action: Action
        switch actionToken {
        case "start", "create": action = .start
        case "attach", "open": action = .attach
        case "list", "ls": action = .list
        case "status", "info": action = .status
        case "close", "kill", "delete": action = .close
        case "help", "--help", "-h": throw CLIError(message: usage)
        default: throw CLIError(message: String.localizedStringWithFormat(
            String(localized: "cli.localZellij.error.unknownSubcommand", defaultValue: "Unknown local-zellij subcommand '%@'.\n%@"),
            actionToken,
            usage
        ))
        }

        var name: String?
        var id: UUID?
        var cwd: String?
        var command: String?
        var request = LocalSessionAttachRequest()
        var detached = false
        var headless = false
        var positional: [String] = []
        var index = 1

        func readValue(_ flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localZellij.error.requiresValue", defaultValue: "local-zellij: %@ requires a value"),
                    flag
                ))
            }
            index += 1
            return arguments[index]
        }

        func parseID(_ raw: String) throws -> UUID {
            guard let parsed = UUID(uuidString: raw) else {
                throw CLIError(message: String(localized: "cli.localZellij.error.invalidID", defaultValue: "local-zellij: --id must be a UUID"))
            }
            return parsed
        }

        func parseFocus(_ raw: String) throws -> Bool {
            switch raw.lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default:
                throw CLIError(message: String(localized: "cli.localZellij.error.invalidFocus", defaultValue: "local-zellij: --focus must be true or false"))
            }
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--":
                positional.append(contentsOf: arguments.dropFirst(index + 1))
                index = arguments.count
                continue
            case "--name", "--session": name = try readValue(argument)
            case let value where value.hasPrefix("--name="): name = String(value.dropFirst("--name=".count))
            case let value where value.hasPrefix("--session="): name = String(value.dropFirst("--session=".count))
            case "--id": id = try parseID(readValue(argument))
            case let value where value.hasPrefix("--id="): id = try parseID(String(value.dropFirst("--id=".count)))
            case "--cwd": cwd = try readValue(argument)
            case let value where value.hasPrefix("--cwd="): cwd = String(value.dropFirst("--cwd=".count))
            case "--command": command = try readValue(argument)
            case let value where value.hasPrefix("--command="): command = String(value.dropFirst("--command=".count))
            case "--workspace": request.workspace = try readValue(argument)
            case let value where value.hasPrefix("--workspace="): request.workspace = String(value.dropFirst("--workspace=".count))
            case "--surface": request.surface = try readValue(argument)
            case let value where value.hasPrefix("--surface="): request.surface = String(value.dropFirst("--surface=".count))
            case "--pane": request.pane = try readValue(argument)
            case let value where value.hasPrefix("--pane="): request.pane = String(value.dropFirst("--pane=".count))
            case "--window": request.window = try readValue(argument)
            case let value where value.hasPrefix("--window="): request.window = String(value.dropFirst("--window=".count))
            case "--focus": request.focus = try parseFocus(readValue(argument))
            case let value where value.hasPrefix("--focus="): request.focus = try parseFocus(String(value.dropFirst("--focus=".count)))
            case "--no-focus": request.focus = false
            case "--detached", "--no-attach": detached = true
            case "--new-client": request.newClient = true
            case "--headless": headless = true
            case "--json": break
            default:
                if argument.hasPrefix("-") {
                    throw CLIError(message: String.localizedStringWithFormat(
                        String(localized: "cli.localZellij.error.unknownFlag", defaultValue: "local-zellij: unknown flag '%@'\n%@"),
                        argument,
                        usage
                    ))
                }
                positional.append(argument)
            }
            index += 1
        }

        if let positionalName = positional.first {
            guard name == nil else {
                throw CLIError(message: String(localized: "cli.localZellij.error.duplicateName", defaultValue: "local-zellij: session name was supplied more than once"))
            }
            name = positionalName
        }
        guard positional.count <= 1 else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.localZellij.error.unexpectedArgument", defaultValue: "local-zellij: unexpected argument '%@'"),
                positional[1]
            ))
        }
        if id != nil, name != nil {
            throw CLIError(message: String(localized: "cli.localZellij.error.selectorConflict", defaultValue: "local-zellij: use either a session name or --id, not both"))
        }
        switch action {
        case .list:
            if name != nil || id != nil {
                throw CLIError(message: String(localized: "cli.localZellij.error.listSelector", defaultValue: "local-zellij list does not take a session selector"))
            }
        case .start:
            if name == nil {
                throw CLIError(message: String(localized: "cli.localZellij.error.startRequiresName", defaultValue: "local-zellij start requires a session name"))
            }
        case .attach, .status, .close:
            if name == nil, id == nil {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localZellij.error.selectorRequired", defaultValue: "local-zellij %@ requires a session name or --id\n%@"),
                    action.rawValue,
                    usage
                ))
            }
        }
        if action != .start, command != nil || cwd != nil {
            throw CLIError(message: String(localized: "cli.localZellij.error.startOnly", defaultValue: "local-zellij --cwd and --command are only valid with start"))
        }
        if action != .start, detached {
            throw CLIError(message: String(localized: "cli.localZellij.error.detachedStartOnly", defaultValue: "local-zellij --detached is only valid with start"))
        }
        if action != .start && action != .attach, request.hasTarget || headless {
            throw CLIError(message: String(localized: "cli.localZellij.error.attachOrStartOnly", defaultValue: "local-zellij workspace, attachment, and --headless options are only valid with start or attach"))
        }
        if request.newClient && action != .attach {
            throw CLIError(message: String(localized: "cli.localZellij.error.newClientOnly", defaultValue: "local-zellij --new-client is only valid with attach"))
        }
        return LocalZellijInvocation(
            action: action,
            name: name,
            id: id,
            cwd: cwd,
            command: command,
            attachRequest: request,
            detached: detached,
            headless: headless
        )
    }

    static var usage: String {
        // A single-line literal keeps the catalog tooling able to read the English source.
        String(localized: "cli.localZellij.usage", defaultValue: "Usage: cmux local-zellij <start|attach|list|status|close> [session] [options]\n\nOpt-in local zellij sessions survive cmux quit, crash, and app updates. Ordinary cmux terminals are unchanged.\n\nstart <name> [--cwd <path>] [--command <shell>] [--detached]\nattach <name|--id <uuid>> [--workspace <id|ref|index>] [--focus <true|false>] [--headless] [--new-client]\nlist [--json]\nstatus <name|--id <uuid>> [--json]\nclose <name|--id <uuid>>\n\nThe registry and zellij socket directory live under ~/.cmux/local-zellij with user-only permissions. `attach --headless` hands the terminal directly to zellij for a client outside the cmux GUI.")
    }
}
