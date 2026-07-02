import Foundation

/// Wrapper-process parser for `livesh --open <sh_id>` bridges. Mirrors `TmuxResumeParser` but
/// emits bindings tagged `kind: "livesh"` so the rest of the resume pipeline
/// (`Workspace.effectiveSurfaceResumeBinding`, `LiveShellChildExitHandler`,
/// `palette.killFocusedLiveShell`) can recognize them.
///
/// Detection contract: a livesh bridge may expose the daemon shell id either as
/// `livesh --open <sh_id>` argv or as a process title such as `livesh (sh_id)`.
/// The id is treated as the resume checkpoint so cmux restart → `livesh --open <id>`
/// reattaches the same daemon-owned shell instead of forking a new one.
enum LiveShellResumeParser {
    static func binding(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String],
        capturedAt: TimeInterval
    ) -> SurfaceResumeBindingSnapshot? {
        let observed = ObservedLiveshProcess(
            processName: processName,
            processPath: processPath,
            arguments: arguments
        )
        guard observed.isLiveshProcess,
              let sessionId = liveshSessionId(observed: observed),
              isSafeSessionID(sessionId) else {
            return nil
        }
        let executable = liveshExecutable(observed: observed)
        let argv = [executable, "--open", sessionId]
        let command = argv.map(shellSingleQuoted).joined(separator: " ")
        let cwd = normalized(environment["CMUX_AGENT_LAUNCH_CWD"] ?? environment["PWD"])
        return SurfaceResumeBindingSnapshot(
            name: "livesh \(sessionId)",
            kind: "livesh",
            command: command,
            cwd: cwd,
            checkpointId: sessionId,
            source: "process-detected",
            environment: nil,
            autoResume: true,
            updatedAt: capturedAt
        )
    }

    static func argumentLooksLikeLivesh(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        if argumentLooksLikeLiveshProcessTitle(normalized) {
            return true
        }
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename == "livesh" || argumentLooksLikeLiveshProcessTitle(basename)
    }

    static func argumentLooksLikeLiveshProcessTitle(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        if normalized.hasPrefix("livesh (") || normalized.hasPrefix("livesh(") {
            return true
        }
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename.hasPrefix("livesh (") || basename.hasPrefix("livesh(")
    }

    private struct ObservedLiveshProcess {
        let processName: String
        let processPath: String?
        let arguments: [String]

        var executableBasenames: [String] {
            var names: [String] = []
            if !processName.isEmpty { names.append(processName) }
            if let processPath, !processPath.isEmpty {
                names.append((processPath as NSString).lastPathComponent)
            }
            if let first = arguments.first, !first.isEmpty {
                names.append((first as NSString).lastPathComponent)
            }
            var seen = Set<String>()
            return names.filter { seen.insert($0).inserted }
        }

        var isLiveshProcess: Bool {
            executableBasenames.contains(where: LiveShellResumeParser.argumentLooksLikeLivesh)
        }
    }

    private static func liveshExecutable(observed: ObservedLiveshProcess) -> String {
        if let first = normalized(observed.arguments.first),
           argumentLooksLikeLivesh(first),
           !argumentLooksLikeLiveshProcessTitle(first) {
            return first
        }
        if let path = normalized(observed.processPath),
           argumentLooksLikeLivesh(path),
           !argumentLooksLikeLiveshProcessTitle(path) {
            return path
        }
        return "livesh"
    }

    private static func liveshSessionId(observed: ObservedLiveshProcess) -> String? {
        if let sessionId = liveshSessionId(in: observed.arguments) {
            return sessionId
        }
        if let sessionId = liveshSessionId(inProcessTitle: observed.processName) {
            return sessionId
        }
        return observed.arguments.lazy.compactMap(liveshSessionId(inProcessTitle:)).first
    }

    private static func liveshSessionId(in arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--open" {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else { return nil }
                return normalized(arguments[valueIndex])
            }
            let prefix = "--open="
            if argument.hasPrefix(prefix) {
                return normalized(String(argument.dropFirst(prefix.count)))
            }
            index += 1
        }
        return nil
    }

    private static func liveshSessionId(inProcessTitle rawValue: String) -> String? {
        guard let value = normalized(rawValue) else { return nil }
        for candidate in processTitleCandidates(from: value) {
            guard let sessionId = liveshSessionId(inProcessTitleCandidate: candidate) else {
                continue
            }
            return sessionId
        }
        return nil
    }

    private static func processTitleCandidates(from value: String) -> [String] {
        let basename = (value as NSString).lastPathComponent
        return basename == value ? [value] : [value, basename]
    }

    private static func liveshSessionId(inProcessTitleCandidate value: String) -> String? {
        guard let titleStart = liveshProcessTitleStart(in: value),
              let open = value[titleStart...].firstIndex(of: "("),
              let close = value[value.index(after: open)...].firstIndex(of: ")") else {
            return nil
        }
        let candidate = String(value[value.index(after: open)..<close])
        guard candidate.hasPrefix("sh_") else { return nil }
        return normalized(candidate)
    }

    private static func liveshProcessTitleStart(in value: String) -> String.Index? {
        var searchStart = value.startIndex
        while searchStart < value.endIndex,
              let range = value.range(
                  of: "livesh",
                  options: [.caseInsensitive],
                  range: searchStart..<value.endIndex
              ) {
            let isPathComponentStart = range.lowerBound == value.startIndex ||
                value[value.index(before: range.lowerBound)] == "/"
            if isPathComponentStart,
               let suffixStart = liveshProcessTitleSuffixStart(after: range.upperBound, in: value) {
                return suffixStart
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func liveshProcessTitleSuffixStart(
        after executableEnd: String.Index,
        in value: String
    ) -> String.Index? {
        guard executableEnd < value.endIndex else { return nil }
        if value[executableEnd] == "(" {
            return value.index(executableEnd, offsetBy: -("livesh".count))
        }
        guard value[executableEnd] == " " else { return nil }
        let open = value.index(after: executableEnd)
        guard open < value.endIndex, value[open] == "(" else { return nil }
        return value.index(executableEnd, offsetBy: -("livesh".count))
    }

    /// Session ids generated by liveshd ought to be `sh_<uuid>`-shaped, but be permissive
    /// (allow letters, digits, `.`, `_`, `-`) while rejecting anything with shell metacharacters
    /// or whitespace — we will feed this into a shell command via `--open {{sessionId}}` so it
    /// must not be able to break out of the argument.
    private static func isSafeSessionID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
