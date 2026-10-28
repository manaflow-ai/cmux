/// Names a process without exposing arbitrary argv in desktop notifications.
public struct RunawaySessionCommandLabeler: Sendable {
    /// Interpreters whose script argument names the command better.
    public let interpreters: Set<String>
    /// Maximum label length in characters.
    public let maximumLength: Int

    /// Creates a labeler.
    public init(
        interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "perl", "java"],
        maximumLength: Int = 60
    ) {
        self.interpreters = interpreters
        self.maximumLength = max(8, maximumLength)
    }

    /// Uses the process name, or an allowlisted tool and subcommand such as
    /// `next dev`. Paths, option values, code and other arguments stay private.
    public func label(arguments: [String], processName: String) -> String {
        let name = basename(processName)
        var label = name
        let commands: [String: Set<String>] = [
            "next": ["dev", "build", "start"],
            "vite": ["dev", "build", "preview"],
            "webpack": ["serve", "watch"],
        ]
        // Only argv[1] may name a script. Looking past arbitrary flags could
        // mistake a credential or inline program for a script name.
        if isInterpreter(name), arguments.count > 1 {
            let script = basename(arguments[1])
            if let subcommands = commands[script] {
                label = script
                if arguments.count > 2, subcommands.contains(arguments[2]) {
                    label += " " + arguments[2]
                }
            }
        }
        guard label.count > maximumLength else { return label }
        return String(label.prefix(maximumLength - 1)) + "…"
    }

    /// Versioned names such as `python3.12` count as their interpreter.
    private func isInterpreter(_ name: String) -> Bool {
        interpreters.contains(name) || interpreters.contains {
            name.hasPrefix($0) && name.dropFirst($0.count).allSatisfy { $0.isNumber || $0 == "." }
        }
    }

    private func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let name = path[path.index(after: slash)...]
        return name.isEmpty ? path : String(name)
    }
}
