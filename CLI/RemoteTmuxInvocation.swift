import Foundation

/// Parsed arguments for the remote-tmux CLI surface.
struct RemoteTmuxInvocation: Equatable {
    enum Action: Equatable {
        case mirror
        case list
        case attach(session: String)
    }

    let action: Action
    let destination: String
    let port: Int?
    let identityFile: String?
    let workspaceName: String?
    let focus: Bool?
    let newWindow: Bool
    let transport: String?
    let transportPort: Int?
    let transportHelperPath: String?
    let broker: String?

    /// Parses `cmux ssh-tmux` arguments, including the list/attach subcommands.
    ///
    /// The destination remains the first positional argument for compatibility with the
    /// existing command. The default action is the historical bulk mirror.
    static func parse(_ commandArgs: [String]) throws -> RemoteTmuxInvocation {
        var destination: String?
        var action: Action?
        var requestedSession: String?
        var port: Int?
        var identityFile: String?
        var workspaceName: String?
        var focus: Bool?
        var newWindow = false
        var transport: String?
        var transportPort: Int?
        var transportHelperPath: String?
        var broker: String?

        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            switch arg {
            case "--port":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh-tmux: --port requires a value")
                }
                guard let parsed = Int(commandArgs[index + 1]), parsed > 0, parsed <= 65535 else {
                    throw CLIError(message: "ssh-tmux: --port must be 1-65535")
                }
                port = parsed
                index += 2
            case "--identity":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh-tmux: --identity requires a path")
                }
                identityFile = commandArgs[index + 1]
                index += 2
            case "--name":
                guard index + 1 < commandArgs.count,
                      !commandArgs[index + 1].hasPrefix("-") else {
                    throw CLIError(message: String(localized: "cli.sshTmux.error.nameRequiresTitle", defaultValue: "ssh-tmux: --name requires a workspace title"))
                }
                workspaceName = commandArgs[index + 1]
                index += 2
            case "--session":
                guard index + 1 < commandArgs.count,
                      !commandArgs[index + 1].hasPrefix("-") else {
                    throw CLIError(message: "ssh-tmux: --session requires a session name")
                }
                guard action != .list else {
                    throw CLIError(message: "ssh-tmux list does not accept --session")
                }
                guard requestedSession == nil else {
                    throw CLIError(message: "ssh-tmux: session selector was specified more than once")
                }
                requestedSession = commandArgs[index + 1]
                index += 2
            case "--transport":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh-tmux: --transport requires a value (ssh or et)")
                }
                let raw = commandArgs[index + 1].lowercased()
                guard raw == "ssh" || raw == "et" else {
                    throw CLIError(message: "ssh-tmux: --transport must be ssh or et")
                }
                transport = raw
                index += 2
            case "--transport-port":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh-tmux: --transport-port requires a value")
                }
                guard let parsed = Int(commandArgs[index + 1]), parsed > 0, parsed <= 65535 else {
                    throw CLIError(message: "ssh-tmux: --transport-port must be 1-65535")
                }
                transportPort = parsed
                index += 2
            case "--transport-helper-path":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: String(
                        localized: "cli.sshTmux.error.helperPathRequired",
                        defaultValue: "ssh-tmux: --transport-helper-path requires an absolute path"
                    ))
                }
                let path = commandArgs[index + 1]
                guard path.hasPrefix("/") else {
                    throw CLIError(message: String(
                        localized: "cli.sshTmux.error.helperPathRequired",
                        defaultValue: "ssh-tmux: --transport-helper-path requires an absolute path"
                    ))
                }
                transportHelperPath = path
                index += 2
            case "--broker":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh-tmux: --broker requires the name of a broker declared under remoteTmux.brokers in cmux.json")
                }
                let name = commandArgs[index + 1].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.hasPrefix("-") else {
                    throw CLIError(message: "ssh-tmux: --broker requires a broker name, for example --broker corp")
                }
                broker = name
                index += 2
            case _ where arg == "--no-focus" || arg == "--focus" || arg.hasPrefix("--focus="):
                let flag = try Self.openFocusFlag(in: commandArgs, at: index)
                focus = flag?.focus
                index += flag?.consumed ?? 1
            case "--new-window":
                newWindow = true
                index += 1
            default:
                guard !arg.hasPrefix("-") else {
                    throw CLIError(
                        message: "ssh-tmux: destination must be <user@host> or an ssh alias. Use --port/--identity for SSH flags."
                    )
                }
                if destination == nil {
                    destination = arg
                } else if action == nil, ["list", "ls", "attach"].contains(arg.lowercased()) {
                    switch arg.lowercased() {
                    case "list", "ls": action = .list
                    case "attach": action = .attach(session: "")
                    default: break
                    }
                } else if case .attach = action, requestedSession == nil {
                    requestedSession = arg
                } else {
                    throw CLIError(message: "ssh-tmux: unexpected extra argument '\(arg)'")
                }
                index += 1
            }
        }

        guard let destination else {
            throw CLIError(message: "ssh-tmux requires a destination (example: cmux ssh-tmux user@host)")
        }

        let resolvedAction: Action
        switch action {
        case .list:
            guard requestedSession == nil else {
                throw CLIError(message: "ssh-tmux list does not accept a session selector")
            }
            guard workspaceName == nil, newWindow == false, focus == nil else {
                throw CLIError(message: "ssh-tmux list only accepts connection options")
            }
            resolvedAction = .list
        case .attach:
            guard let requestedSession = requestedSession?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !requestedSession.isEmpty else {
                throw CLIError(message: "ssh-tmux attach requires a session name")
            }
            resolvedAction = .attach(session: requestedSession)
        case .mirror:
            resolvedAction = .mirror
        case nil:
            guard requestedSession == nil else {
                guard let requestedSession = requestedSession?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !requestedSession.isEmpty else {
                    throw CLIError(message: "ssh-tmux: --session requires a session name")
                }
                resolvedAction = .attach(session: requestedSession)
                return RemoteTmuxInvocation(
                    action: resolvedAction, destination: destination, port: port,
                    identityFile: identityFile, workspaceName: workspaceName, focus: focus,
                    newWindow: newWindow, transport: transport, transportPort: transportPort,
                    transportHelperPath: transportHelperPath, broker: broker)
            }
            resolvedAction = .mirror
        }

        if resolvedAction == .list, workspaceName != nil || newWindow || focus != nil {
            throw CLIError(message: "ssh-tmux list only accepts connection options")
        }
        return RemoteTmuxInvocation(
            action: resolvedAction, destination: destination, port: port,
            identityFile: identityFile, workspaceName: workspaceName, focus: focus,
            newWindow: newWindow, transport: transport, transportPort: transportPort,
            transportHelperPath: transportHelperPath, broker: broker)
    }

    private static func openFocusFlag(
        in args: [String],
        at index: Int
    ) throws -> (focus: Bool, consumed: Int)? {
        let arg = args[index]
        if arg == "--no-focus" { return (false, 1) }
        if arg == "--focus" {
            if index + 1 < args.count, let value = focusFlagValue(args[index + 1]) {
                return (value, 2)
            }
            return (true, 1)
        }
        guard arg.hasPrefix("--focus=") else { return nil }
        guard let value = focusFlagValue(String(arg.dropFirst("--focus=".count))) else {
            throw CLIError(message: "ssh-tmux: --focus takes true or false")
        }
        return (value, 1)
    }

    private static func focusFlagValue(_ token: String) -> Bool? {
        switch token.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
}
