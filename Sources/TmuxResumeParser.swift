import Foundation

enum TmuxResumeParser {
    static func binding(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String],
        capturedAt: TimeInterval
    ) -> SurfaceResumeBindingSnapshot? {
        let observed = ObservedTmuxProcess(
            processName: processName,
            processPath: processPath,
            arguments: arguments
        )
        guard let invocation = resumeInvocation(observed: observed) else { return nil }

        let command = invocation.argv.map(shellSingleQuoted).joined(separator: " ")
        let cwd = normalized(environment["CMUX_AGENT_LAUNCH_CWD"] ?? environment["PWD"])
        let resumeEnvironment = tmuxResumeEnvironment(from: environment)
        return SurfaceResumeBindingSnapshot(
            name: invocation.sessionName.map { "tmux \($0)" } ?? "tmux",
            kind: "tmux",
            command: command,
            cwd: cwd,
            checkpointId: invocation.sessionName,
            source: "process-detected",
            environment: resumeEnvironment,
            autoResume: true,
            updatedAt: capturedAt
        )
    }

    static func argumentLooksLikeTmux(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        if argumentLooksLikeTmuxClientProcessTitle(normalized) {
            return true
        }
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename == "tmux" || argumentLooksLikeTmuxClientProcessTitle(basename)
    }

    static func argumentLooksLikeTmuxProcessTitle(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        if normalized.hasPrefix("tmux:") {
            return true
        }
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename.hasPrefix("tmux:")
    }

    static func argumentLooksLikeTmuxServerProcessTitle(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        if normalized.hasPrefix("tmux: server") {
            return true
        }
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename.hasPrefix("tmux: server")
    }

    private struct ObservedTmuxProcess {
        let processName: String
        let processPath: String?
        let arguments: [String]

        var executableBasenames: [String] {
            var names: [String] = []
            if !processName.isEmpty { names.append(processName) }
            if let processPath, !processPath.isEmpty { names.append((processPath as NSString).lastPathComponent) }
            if let first = arguments.first, !first.isEmpty { names.append((first as NSString).lastPathComponent) }
            var seen = Set<String>()
            return names.filter { seen.insert($0).inserted }
        }

        var isTmuxProcess: Bool {
            executableBasenames.contains(where: TmuxResumeParser.argumentLooksLikeTmux)
        }

        var hasTmuxServerProcessTitle: Bool {
            executableBasenames.contains(where: TmuxResumeParser.argumentLooksLikeTmuxServerProcessTitle)
        }
    }

    private struct TmuxResumeInvocation {
        let argv: [String]
        let sessionName: String?
    }

    private static func resumeInvocation(observed: ObservedTmuxProcess) -> TmuxResumeInvocation? {
        guard observed.isTmuxProcess else { return nil }
        guard !observed.hasTmuxServerProcessTitle else { return nil }

        let executable = tmuxExecutable(observed: observed)
        let tail = tmuxTailArguments(observed: observed)
        let parsed = parseTopLevelArguments(tail)
        guard parsed.isSafe else { return nil }

        var argv = [executable]
        argv.append(contentsOf: parsed.socketFlags)
        argv.append("attach")
        if let sessionName = parsed.sessionName {
            argv.append(contentsOf: ["-t", sessionName])
        }
        return TmuxResumeInvocation(argv: argv, sessionName: parsed.sessionName)
    }

    private static func tmuxExecutable(observed: ObservedTmuxProcess) -> String {
        if let first = normalized(observed.arguments.first),
           argumentLooksLikeTmux(first),
           !argumentLooksLikeTmuxProcessTitle(first) {
            return first
        }
        if let path = normalized(observed.processPath),
           argumentLooksLikeTmux(path),
           !argumentLooksLikeTmuxProcessTitle(path) {
            return path
        }
        return "tmux"
    }

    private static func tmuxTailArguments(observed: ObservedTmuxProcess) -> [String] {
        guard let first = observed.arguments.first else { return [] }
        return argumentLooksLikeTmux(first)
            ? Array(observed.arguments.dropFirst())
            : observed.arguments
    }

    private struct ParsedTmuxTopLevelArguments {
        let socketFlags: [String]
        let sessionName: String?
        let isSafe: Bool
    }

    private static func parseTopLevelArguments(_ arguments: [String]) -> ParsedTmuxTopLevelArguments {
        var index = 0
        var socketFlags: [String] = []

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                break
            }
            guard argument.hasPrefix("-") else { break }
            if appendSocketFlag(argument, arguments: arguments, index: &index, into: &socketFlags) {
                continue
            }
            index += topLevelOptionWidth(argument, arguments: arguments, index: index)
        }

        guard index < arguments.count else {
            return ParsedTmuxTopLevelArguments(socketFlags: socketFlags, sessionName: nil, isSafe: false)
        }

        let command = arguments[index]
        let commandArgs = Array(arguments.dropFirst(index + 1))
        switch command {
        case "attach-session", "attach", "a":
            let sessionName = optionValue(commandArgs, short: "t", long: "target-session")
            guard sessionName != nil else {
                return ParsedTmuxTopLevelArguments(socketFlags: socketFlags, sessionName: nil, isSafe: false)
            }
            return ParsedTmuxTopLevelArguments(
                socketFlags: socketFlags,
                sessionName: sessionName,
                isSafe: true
            )
        case "new-session", "new":
            guard hasFlag(commandArgs, short: "A") else {
                return ParsedTmuxTopLevelArguments(socketFlags: socketFlags, sessionName: nil, isSafe: false)
            }
            let sessionName = optionValue(commandArgs, short: "s", long: "session-name")
            guard sessionName != nil else {
                return ParsedTmuxTopLevelArguments(socketFlags: socketFlags, sessionName: nil, isSafe: false)
            }
            return ParsedTmuxTopLevelArguments(
                socketFlags: socketFlags,
                sessionName: sessionName,
                isSafe: true
            )
        default:
            return ParsedTmuxTopLevelArguments(socketFlags: socketFlags, sessionName: nil, isSafe: false)
        }
    }

    private static func appendSocketFlag(
        _ argument: String,
        arguments: [String],
        index: inout Int,
        into socketFlags: inout [String]
    ) -> Bool {
        for option in ["L", "S"] {
            let short = "-\(option)"
            if argument == short {
                let valueIndex = index + 1
                guard valueIndex < arguments.count,
                      let value = normalized(arguments[valueIndex]) else {
                    index = valueIndex
                    return true
                }
                socketFlags.append(contentsOf: [short, value])
                index += 2
                return true
            }
            if argument.hasPrefix(short), argument.count > short.count {
                let value = String(argument.dropFirst(short.count))
                if let normalizedValue = normalized(value) {
                    socketFlags.append(contentsOf: [short, normalizedValue])
                }
                index += 1
                return true
            }
        }
        return false
    }

    private static func topLevelOptionWidth(_ argument: String, arguments: [String], index: Int) -> Int {
        if argument.contains("=") { return 1 }
        let valueOptions: Set<String> = ["-c", "-f"]
        guard valueOptions.contains(argument), index + 1 < arguments.count else { return 1 }
        return 2
    }

    private static func hasFlag(_ arguments: [String], short: Character, long: String? = nil) -> Bool {
        for argument in arguments {
            if argument == "--" { break }
            if let long, argument == "--\(long)" { return true }
            if argument == "-\(short)" { return true }
            if shortFlagCluster(argument, contains: short) {
                return true
            }
        }
        return false
    }

    private static func shortFlagCluster(_ argument: String, contains short: Character) -> Bool {
        guard argument.hasPrefix("-"), !argument.hasPrefix("--") else { return false }
        for option in argument.dropFirst() {
            if option == short { return true }
            if valueOptionCharacters.contains(option) { return false }
        }
        return false
    }

    private static let valueOptionCharacters: Set<Character> = {
        ["c", "e", "F", "f", "n", "s", "t", "x", "y"]
    }()

    private enum ClusterValueMatch {
        case inline(String)
        case nextArgument
    }

    private static func clusterValue(_ argument: String, short: Character) -> ClusterValueMatch? {
        guard argument.hasPrefix("-"), !argument.hasPrefix("--") else { return nil }
        var index = argument.index(after: argument.startIndex)
        while index < argument.endIndex {
            let option = argument[index]
            let nextIndex = argument.index(after: index)
            if option == short {
                if nextIndex < argument.endIndex {
                    return .inline(String(argument[nextIndex...]))
                }
                return .nextArgument
            }
            if valueOptionCharacters.contains(option) {
                return nil
            }
            index = nextIndex
        }
        return nil
    }

    private static func optionValue(_ arguments: [String], short: Character, long: String) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            if argument == "--\(long)" || argument == "-\(short)" {
                return valueAfter(arguments, index: index)
            }
            let longPrefix = "--\(long)="
            if argument.hasPrefix(longPrefix) {
                return normalized(String(argument.dropFirst(longPrefix.count)))
            }
            let shortPrefix = "-\(short)"
            if argument.hasPrefix(shortPrefix), argument.count > shortPrefix.count {
                return normalized(String(argument.dropFirst(shortPrefix.count)))
            }
            if let clusterValue = clusterValue(argument, short: short) {
                if case .inline(let value) = clusterValue {
                    return normalized(value)
                }
                return valueAfter(arguments, index: index)
            }
            index += 1
        }
        return nil
    }

    private static func valueAfter(_ arguments: [String], index: Int) -> String? {
        let nextIndex = index + 1
        guard nextIndex < arguments.count else { return nil }
        guard arguments[nextIndex] != "--" else { return nil }
        return normalized(arguments[nextIndex])
    }

    private static func argumentLooksLikeTmuxClientProcessTitle(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        if normalized.hasPrefix("tmux: client") {
            return true
        }
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename.hasPrefix("tmux: client")
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func tmuxResumeEnvironment(from environment: [String: String]) -> [String: String]? {
        guard let tmuxTmpDir = normalized(environment["TMUX_TMPDIR"]) else { return nil }
        return ["TMUX_TMPDIR": tmuxTmpDir]
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
}
