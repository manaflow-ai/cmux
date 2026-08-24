import Foundation

struct LocalTmuxInvocation {
    enum Action: String {
        case start
        case attach
        case list
        case status
        case detach
        case close
        case cleanup
    }

    let action: Action
    let name: String?
    let id: UUID?
    let cwd: String?
    let command: String?
    let workspace: String?
    let surface: String?
    let pane: String?
    let window: String?
    let focus: Bool?
    let detached: Bool
    let newClient: Bool
    let headless: Bool
    let clientID: String?
    let all: Bool
    let prune: Bool

    var canRunWithoutCmux: Bool {
        switch action {
        case .list, .status, .detach, .close, .cleanup:
            return true
        case .start:
            return detached || headless
        case .attach:
            return headless
        }
    }

    static func parse(_ arguments: [String]) throws -> LocalTmuxInvocation {
        guard let actionToken = arguments.first?.lowercased() else {
            throw CLIError(message: usage)
        }
        let action: Action
        switch actionToken {
        case "start", "create": action = .start
        case "attach", "open": action = .attach
        case "list", "ls": action = .list
        case "status", "info": action = .status
        case "detach": action = .detach
        case "close", "kill", "delete": action = .close
        case "cleanup", "prune": action = .cleanup
        case "help", "--help", "-h": throw CLIError(message: usage)
        default: throw CLIError(message: "Unknown local-tmux subcommand '\(actionToken)'.\n\(usage)")
        }

        var name: String?
        var id: UUID?
        var cwd: String?
        var command: String?
        var workspace: String?
        var surface: String?
        var pane: String?
        var window: String?
        var focus: Bool?
        var detached = false
        var newClient = false
        var headless = false
        var clientID: String?
        var all = false
        var prune = false
        var positional: [String] = []
        var index = 1

        func readValue(_ flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw CLIError(message: "local-tmux: \(flag) requires a value")
            }
            index += 1
            return arguments[index]
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
            case "--id":
                guard let parsed = UUID(uuidString: try readValue(argument)) else {
                    throw CLIError(message: "local-tmux: --id must be a UUID")
                }
                id = parsed
            case let value where value.hasPrefix("--id="):
                guard let parsed = UUID(uuidString: String(value.dropFirst("--id=".count))) else {
                    throw CLIError(message: "local-tmux: --id must be a UUID")
                }
                id = parsed
            case "--cwd": cwd = try readValue(argument)
            case let value where value.hasPrefix("--cwd="): cwd = String(value.dropFirst("--cwd=".count))
            case "--command": command = try readValue(argument)
            case let value where value.hasPrefix("--command="): command = String(value.dropFirst("--command=".count))
            case "--workspace": workspace = try readValue(argument)
            case let value where value.hasPrefix("--workspace="): workspace = String(value.dropFirst("--workspace=".count))
            case "--surface": surface = try readValue(argument)
            case let value where value.hasPrefix("--surface="): surface = String(value.dropFirst("--surface=".count))
            case "--pane": pane = try readValue(argument)
            case let value where value.hasPrefix("--pane="): pane = String(value.dropFirst("--pane=".count))
            case "--window": window = try readValue(argument)
            case let value where value.hasPrefix("--window="): window = String(value.dropFirst("--window=".count))
            case "--focus":
                guard let parsed = parseBoolean(try readValue(argument)) else {
                    throw CLIError(message: "local-tmux: --focus must be true or false")
                }
                focus = parsed
            case let value where value.hasPrefix("--focus="):
                guard let parsed = parseBoolean(String(value.dropFirst("--focus=".count))) else {
                    throw CLIError(message: "local-tmux: --focus must be true or false")
                }
                focus = parsed
            case "--no-focus": focus = false
            case "--detached", "--no-attach": detached = true
            case "--new-client": newClient = true
            case "--headless": headless = true
            case "--client": clientID = try readValue(argument)
            case let value where value.hasPrefix("--client="): clientID = String(value.dropFirst("--client=".count))
            case "--all": all = true
            case "--prune": prune = true
            case "--json": break
            default:
                if argument.hasPrefix("-") {
                    throw CLIError(message: "local-tmux: unknown flag '\(argument)'\n\(usage)")
                }
                positional.append(argument)
            }
            index += 1
        }

        if let positionalName = positional.first {
            guard name == nil else {
                throw CLIError(message: "local-tmux: session name was supplied more than once")
            }
            name = positionalName
        }
        guard positional.count <= 1 else {
            throw CLIError(message: "local-tmux: unexpected argument '\(positional[1])'")
        }
        if id != nil, name != nil {
            throw CLIError(message: "local-tmux: use either a session name or --id, not both")
        }
        if action == .start, id != nil {
            throw CLIError(message: "local-tmux start accepts a name, not --id")
        }
        if action != .list && action != .cleanup && name == nil && id == nil {
            throw CLIError(message: "local-tmux \(action.rawValue) requires a session name or --id\n\(usage)")
        }
        if action == .list, name != nil || id != nil {
            throw CLIError(message: "local-tmux list does not take a session selector")
        }
        if action == .cleanup, name != nil || id != nil {
            throw CLIError(message: "local-tmux cleanup does not take a session selector")
        }
        if action != .start, command != nil || cwd != nil {
            throw CLIError(message: "local-tmux --cwd and --command are only valid with start")
        }
        if action != .detach, clientID != nil || all {
            throw CLIError(message: "local-tmux --client/--all are only valid with detach")
        }
        if action != .cleanup, prune {
            throw CLIError(message: "local-tmux --prune is only valid with cleanup")
        }
        if headless && action != .attach && action != .start {
            throw CLIError(message: "local-tmux --headless is only valid with attach or start")
        }
        if newClient && action != .attach {
            throw CLIError(message: "local-tmux --new-client is only valid with attach")
        }
        return LocalTmuxInvocation(
            action: action,
            name: name,
            id: id,
            cwd: cwd,
            command: command,
            workspace: workspace,
            surface: surface,
            pane: pane,
            window: window,
            focus: focus,
            detached: detached,
            newClient: newClient,
            headless: headless,
            clientID: clientID,
            all: all,
            prune: prune
        )
    }

    static var usage: String {
        String(localized: "cli.localTmux.usage", defaultValue: """
    Usage: cmux local-tmux <start|attach|list|status|detach|close|cleanup> [session] [options]

    Opt-in local tmux sessions survive cmux quit, crash, and app updates.
    Ordinary cmux terminals are unchanged.

    start <name> [--cwd <path>] [--command <shell>] [--detached]
    attach <name|--id <uuid>] [--workspace <id|ref|index>] [--focus <true|false>]
    list [--json]
    status <name|--id <uuid>] [--json]
    detach <name|--id <uuid>] [--client <id> | --all]
    close <name|--id <uuid>]
    cleanup [--prune]

    The registry and tmux server socket live under ~/.cmux/local-tmux with
    user-only permissions. `attach --headless` hands the terminal directly to
    tmux for a client outside the cmux GUI.
    """)
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }
}
