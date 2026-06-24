public import Foundation

/// Argv/environment-only OpenCode process classification and fork-session
/// inference, the entry points the live-process scanner reaches for when it has
/// only a process name, argv, and environment in hand.
///
/// These adapt the scanner's raw `(processName, processPath, arguments,
/// environment)` tuples into a `VaultObservedAgentProcess` and route them
/// through the resolver's path/argv parsing, plus the OpenCode fork-flag
/// session inference that depends only on the argument vector. They were
/// previously static helpers on the app-side session index; folding them onto
/// the resolver keeps OpenCode process detection in one owner and reuses the
/// resolver's injected `FileManager` instead of constructing a throwaway one.
extension OpenCodeProcessResolver {
    /// Reports whether a process described by its name, path, and argv looks
    /// like an OpenCode invocation.
    public func processLooksLikeOpenCode(
        processName: String,
        processPath: String?,
        arguments: [String]
    ) -> Bool {
        VaultObservedAgentProcess(
            processName: processName,
            processPath: processPath,
            arguments: arguments,
            environment: [:]
        ).isOpenCodeProcess
    }

    /// Resolves the OpenCode executable path for a process described by its argv
    /// and environment.
    public func openCodeExecutablePath(
        arguments: [String],
        environment: [String: String]
    ) -> String {
        let observed = VaultObservedAgentProcess(
            processName: "",
            processPath: nil,
            arguments: arguments,
            environment: environment
        )
        return executablePath(observed: observed, environment: environment)
    }

    /// Builds the OpenCode launch argument vector for a process described by its
    /// argv and environment, or `nil` when the arguments cannot be preserved.
    public func openCodeLaunchArguments(
        arguments: [String],
        environment: [String: String]
    ) -> [String]? {
        let observed = VaultObservedAgentProcess(
            processName: "",
            processPath: nil,
            arguments: arguments,
            environment: environment
        )
        let executablePath = executablePath(observed: observed, environment: environment)
        return launchArguments(observed: observed, executablePath: executablePath)
    }

    /// Resolves the OpenCode working directory for a process described by its
    /// argv and environment.
    public func openCodeWorkingDirectory(
        arguments: [String],
        environment: [String: String]
    ) -> String? {
        let observed = VaultObservedAgentProcess(
            processName: "",
            processPath: nil,
            arguments: arguments,
            environment: environment
        )
        return workingDirectory(observed: observed)
    }

    /// Infers the OpenCode session id to fork from an argument vector, honoring
    /// the `--session`/`-s` flags and the fork-flag heuristics; only attributes
    /// a sole-panel session when exactly one panel shares the working directory.
    public func openCodeFallbackSessionId(
        arguments: [String],
        latestSessionIdForSolePanel: String?,
        sameWorkingDirectoryPanelCount: Int
    ) -> String? {
        if arguments.hasOpenCodeForkFlag {
            let explicitSessionId = arguments.value(afterOption: "--session") ?? arguments.value(afterOption: "-s")
            let assignedForkParentSessionId = arguments.openCodeForkParentSessionId
            if let explicitSessionId,
               let assignedForkParentSessionId,
               explicitSessionId != assignedForkParentSessionId {
                return explicitSessionId
            }
            guard sameWorkingDirectoryPanelCount == 1 else { return nil }
            guard let latestSessionIdForSolePanel else { return nil }
            let forkParentSessionId = assignedForkParentSessionId ?? explicitSessionId
            guard let forkParentSessionId else { return nil }
            guard forkParentSessionId != latestSessionIdForSolePanel else { return nil }
            return latestSessionIdForSolePanel
        }
        if let explicitSessionId = arguments.value(afterOption: "--session") ?? arguments.value(afterOption: "-s") {
            return explicitSessionId
        }
        return nil
    }
}
