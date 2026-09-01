import Foundation

/// Matches live Prime Agent processes to a recorded launch without trusting a bare runtime name.
public struct PrimeAgentProcessIdentity: Sendable {
    /// Creates a stateless Prime Agent process-identity matcher.
    public init() {}

    /// Matches a live process against the executable recorded for a Prime Agent session.
    ///
    /// Native `prime-agent` executables match exactly. JavaScript-runtime launches
    /// must also contain a recognized managed coding-agent entrypoint in their argv.
    ///
    /// - Parameters:
    ///   - liveExecutable: The executable basename observed in the live process.
    ///   - recordedExecutable: The executable basename captured for the session.
    ///   - arguments: The complete live process argv, including argv[0].
    /// - Returns: `true` when the live process has the recorded Prime identity.
    public func matchesRecordedProcess(
        liveExecutable: String,
        recordedExecutable: String,
        arguments: [String]
    ) -> Bool {
        let liveBase = Self.processBasename(liveExecutable)
        let recordedBase = Self.processBasename(recordedExecutable)
        if liveBase == "prime-agent" && recordedBase == "prime-agent" {
            return true
        }
        guard Self.runtimeNames.contains(liveBase) else {
            return false
        }
        return matchesRuntimeProcess(processName: liveBase, arguments: arguments)
    }

    /// Matches a runtime-launched Prime Agent process by its managed script entrypoint.
    ///
    /// - Parameters:
    ///   - processName: The process name or executable basename observed by the scanner.
    ///   - arguments: The complete live process argv, including argv[0].
    /// - Returns: `true` only when a supported runtime and Prime coding-agent script are present.
    public func matchesRuntimeProcess(processName: String?, arguments: [String]) -> Bool {
        var runtimeCandidates = [processName]
        if let firstArgument = arguments.first {
            runtimeCandidates.append(firstArgument)
        }
        let normalizedRuntimeCandidates = runtimeCandidates.compactMap { value in
            value.map(Self.processBasename)
        }
        guard normalizedRuntimeCandidates.contains(where: Self.runtimeNames.contains) else {
            return false
        }
        let scriptMatcher = PrimeAgentScriptMatch()
        return arguments.dropFirst().contains(where: scriptMatcher.matches)
    }

    private static let runtimeNames: Set<String> = ["node", "bun", "deno", "tsx", "ts-node"]

    private static func processBasename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
    }
}
