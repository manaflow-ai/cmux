public import CmuxProcess
public import Foundation

/// Resolves a git host into a ready-to-poll ``GitHostingRequestPlan``.
///
/// This is the one stateful entry point of the package, and it is pure value-in /
/// value-out apart from the injected ``CommandRunning`` it uses to look up tokens.
/// It applies, in order: a matching user ``GitHostingConfig/rules`` entry, the
/// built-in auto-detected presets, then GitHub Enterprise Server discovery via the
/// `gh` CLI. It returns `nil` when a host is not pollable (no provider matches, or a
/// non-anonymous provider has no token), so the caller can skip it cleanly.
///
/// Inject the environment and command runner for testability:
///
/// ```swift
/// let resolver = GitHostingResolver(
///     config: .default,
///     environment: ProcessInfo.processInfo.environment,
///     commandRunner: CommandRunner(),
///     workingDirectory: FileManager.default.currentDirectoryPath
/// )
/// let plan = await resolver.resolvePlan(forHost: "github.com")
/// ```
public struct GitHostingResolver: Sendable {
    private let config: GitHostingConfig
    private let environment: [String: String]
    private let commandRunner: any CommandRunning
    private let workingDirectory: String
    private let tokenCommandTimeout: TimeInterval

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - config: The user's git hosting configuration.
    ///   - environment: The process environment used for env-var token lookups.
    ///   - commandRunner: The seam used to run token commands (`gh`, `glab`, …).
    ///   - workingDirectory: The directory token commands run in.
    ///   - tokenCommandTimeout: The per-command timeout in seconds. Defaults to 5.
    public init(
        config: GitHostingConfig,
        environment: [String: String],
        commandRunner: any CommandRunning,
        workingDirectory: String,
        tokenCommandTimeout: TimeInterval = 5
    ) {
        self.config = config
        self.environment = environment
        self.commandRunner = commandRunner
        self.workingDirectory = workingDirectory
        self.tokenCommandTimeout = tokenCommandTimeout
    }

    /// Resolves a plan for `host`, or `nil` when the host is not pollable.
    ///
    /// - Parameters:
    ///   - host: The remote host (case-insensitive).
    ///   - port: An explicit HTTPS API port pinned by the remote, if any.
    public func resolvePlan(forHost host: String, port: Int? = nil) async -> GitHostingRequestPlan? {
        let normalizedHost = host.lowercased()
        let apiHost = port.map { "\(normalizedHost):\($0)" } ?? normalizedHost

        if let rule = config.rule(matchingHost: normalizedHost), let spec = rule.resolvedSpec() {
            return await makePlan(spec: spec, host: normalizedHost, apiHost: apiHost)
        }

        if config.autoDetect, let preset = GitHostingPreset.builtIn(forHost: normalizedHost) {
            return await makePlan(spec: preset.spec, host: normalizedHost, apiHost: apiHost)
        }

        if config.autoDiscoverGitHubEnterprise {
            let discovery = GitHostingTokenSource(command: ["gh", "auth", "token", "--hostname", "{host}"])
            if let token = await resolveToken(discovery, host: normalizedHost) {
                var spec = GitHostingPreset.github.spec
                spec.apiBaseURL = "https://{host}/api/v3/"
                return GitHostingRequestPlan(spec: spec, apiHost: apiHost, token: token)
            }
        }

        return nil
    }

    private func makePlan(
        spec: GitHostingProviderSpec,
        host: String,
        apiHost: String
    ) async -> GitHostingRequestPlan? {
        let token = await resolveToken(spec.auth.token, host: host)
        if token == nil && !spec.auth.allowsAnonymous {
            return nil
        }
        return GitHostingRequestPlan(spec: spec, apiHost: apiHost, token: token)
    }

    private func resolveToken(_ source: GitHostingTokenSource, host: String) async -> String? {
        for name in source.environment {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        guard let command = source.command, let executable = command.first else { return nil }
        let arguments = command.dropFirst().map { $0.replacingOccurrences(of: "{host}", with: host) }
        let output = await commandRunner.runStandardOutput(
            directory: workingDirectory,
            executable: executable,
            arguments: Array(arguments),
            timeout: tokenCommandTimeout
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, !output.isEmpty else { return nil }
        return output
    }
}
