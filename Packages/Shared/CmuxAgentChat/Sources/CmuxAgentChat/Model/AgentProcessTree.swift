import Foundation

/// An agent's process subtree from one census, used to find the command it runs
/// in its terminal's foreground.
///
/// Agents run tool commands through a shell they spawn (`zsh -c ...`). Long-lived
/// helpers such as MCP servers are also children of the agent but are not shells,
/// so only a shell child in the terminal's foreground process group counts.
public struct AgentProcessTree: Sendable {
    /// One process from a census.
    public struct Process: Sendable, Equatable {
        public var pid: Int
        public var parentPID: Int
        public var name: String
        public var isTerminalForeground: Bool
        public var startedAt: Date?

        public init(pid: Int, parentPID: Int, name: String, isTerminalForeground: Bool, startedAt: Date? = nil) {
            self.pid = pid
            self.parentPID = parentPID
            self.name = name
            self.isTerminalForeground = isTerminalForeground
            self.startedAt = startedAt
        }
    }

    public static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]
    public static let maximumLength = 120
    static let maximumDepth = 32

    /// The census, keyed by pid.
    public var processes: [Int: Process]

    public init(processes: [Int: Process]) {
        self.processes = processes
    }

    /// The deepest foreground process under the agent's newest foreground shell child.
    ///
    /// - Parameters:
    ///   - agentPID: The agent process.
    ///   - notBefore: Ignore shells started earlier (for example before the current turn).
    /// - Returns: The pid whose argv describes the command, or nil when none runs.
    public func foregroundCommandPID(agentPID: Int, notBefore: Date? = nil) -> Int? {
        guard agentPID > 0 else { return nil }
        var children: [Int: [Process]] = [:]
        for process in processes.values where process.pid != process.parentPID {
            children[process.parentPID, default: []].append(process)
        }
        func newest(_ candidates: [Process]) -> Process? {
            candidates.max { lhs, rhs in
                (lhs.startedAt ?? .distantPast, lhs.pid) < (rhs.startedAt ?? .distantPast, rhs.pid)
            }
        }
        let shells = (children[agentPID] ?? []).filter { process in
            guard process.pid != agentPID, process.isTerminalForeground,
                  Self.shellNames.contains(Self.normalizedName(process.name)) else { return false }
            if let notBefore, let startedAt = process.startedAt, startedAt < notBefore { return false }
            return true
        }
        guard var current = newest(shells) else { return nil }
        for _ in 0..<Self.maximumDepth {
            guard let next = newest((children[current.pid] ?? []).filter(\.isTerminalForeground)) else { break }
            current = next
        }
        return current.pid
    }

    /// One line for a process's argv. A shell's `-c` script is shown instead of the shell.
    public static func describe(arguments: [String]) -> String? {
        guard let first = arguments.first else { return nil }
        var words = arguments
        let executable = normalizedName((first as NSString).lastPathComponent)
        if shellNames.contains(executable),
           arguments.dropFirst().contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }),
           let script = arguments.last, !script.hasPrefix("-") {
            words = [script]
        } else {
            words[0] = (first as NSString).lastPathComponent
        }
        let line = words.joined(separator: " ")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > maximumLength ? String(line.prefix(maximumLength - 1)) + "…" : line
    }

    private static func normalizedName(_ name: String) -> String {
        name.hasPrefix("-") ? String(name.dropFirst()) : name
    }
}
