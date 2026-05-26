import Foundation

enum AgentSessionProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return String(localized: "agentSession.provider.codex", defaultValue: "Codex")
        case .claude:
            return String(localized: "agentSession.provider.claude", defaultValue: "Claude Code")
        case .opencode:
            return String(localized: "agentSession.provider.opencode", defaultValue: "OpenCode")
        }
    }

    var executableName: String {
        switch self {
        case .codex:
            return "codex"
        case .claude:
            return "claude"
        case .opencode:
            return "opencode"
        }
    }

    var launchArguments: [String] {
        switch self {
        case .codex:
            return ["app-server", "--listen", "stdio://"]
        case .claude:
            return [
                "-p",
                "--output-format", "stream-json",
                "--input-format", "stream-json",
                "--permission-prompt-tool", "stdio",
                "--include-partial-messages",
                "--verbose"
            ]
        case .opencode:
            return ["serve", "--hostname", "127.0.0.1", "--port", "0", "--print-logs"]
        }
    }

    var transportKind: String {
        switch self {
        case .codex:
            return "stdio-jsonrpc"
        case .claude:
            return "stdio-jsonl"
        case .opencode:
            return "http-loopback"
        }
    }

    var shouldAutoStartSession: Bool {
        switch self {
        case .codex, .opencode:
            return true
        case .claude:
            return false
        }
    }
}

enum AgentSessionRendererKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case react
    case solid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .react:
            return String(localized: "agentSession.renderer.react", defaultValue: "React")
        case .solid:
            return String(localized: "agentSession.renderer.solid", defaultValue: "Solid")
        }
    }

    var resourceDirectoryName: String {
        switch self {
        case .react:
            return "agent-session-react"
        case .solid:
            return "agent-session-solid"
        }
    }
}

struct AgentSessionLaunchPlan: Equatable, Sendable {
    let provider: AgentSessionProviderID
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

enum AgentExecutableResolverError: LocalizedError, Equatable {
    case missing(displayName: String, executableName: String, searchedDirectories: [String])

    var message: String {
        switch self {
        case .missing(let displayName, let executableName, _):
            let format = String(
                localized: "agentSession.error.missingProviderExecutable",
                defaultValue: "%@ was not found. Install it and make sure \"%@\" is available on PATH."
            )
            return String(format: format, displayName, executableName)
        }
    }

    var errorDescription: String? {
        message
    }
}

struct AgentExecutableResolver {
    var environment: [String: String]
    var fileManager: FileManager
    var bundleResourceURL: URL?
    var extraSearchDirectories: [String]
    var configuredExecutablePaths: [AgentSessionProviderID: String]

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        extraSearchDirectories: [String] = [],
        configuredExecutablePaths: [AgentSessionProviderID: String] = [:]
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.bundleResourceURL = bundleResourceURL
        self.extraSearchDirectories = extraSearchDirectories
        self.configuredExecutablePaths = configuredExecutablePaths
    }

    func resolve(_ provider: AgentSessionProviderID) throws -> AgentSessionLaunchPlan {
        let executableName = provider.executableName
        let searchDirectories = resolvedSearchDirectories()
        if let configuredURL = resolvedConfiguredExecutableURL(for: provider) {
            return launchPlan(provider: provider, executableURL: configuredURL, searchDirectories: searchDirectories)
        }

        for directory in searchDirectories {
            guard !shouldSkipSearchDirectory(directory) else { continue }
            let candidateURL = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executableName, isDirectory: false)
                .standardizedFileURL
            let candidatePath = candidateURL.path
            guard fileManager.isExecutableFile(atPath: candidatePath) else { continue }
            guard !isBundledProviderExecutable(candidateURL) else { continue }
            guard !isKnownCmuxClaudeWrapper(candidateURL, provider: provider) else { continue }

            return launchPlan(provider: provider, executableURL: candidateURL, searchDirectories: searchDirectories)
        }

        throw AgentExecutableResolverError.missing(
            displayName: provider.displayName,
            executableName: executableName,
            searchedDirectories: searchDirectories
        )
    }

    static func cmuxConfiguredExecutablePaths(defaults: UserDefaults = .standard) -> [AgentSessionProviderID: String] {
        guard let claudePath = ClaudeCodeIntegrationSettings.customClaudePath(defaults: defaults) else {
            return [:]
        }
        return [.claude: claudePath]
    }

    func resolvedSearchDirectories() -> [String] {
        var directories: [String] = []
        let pathValue = environment["PATH"] ?? ""
        directories.append(contentsOf: pathValue.split(separator: ":").map(String.init))
        directories.append(contentsOf: extraSearchDirectories)
        if let home = environment["HOME"], !home.isEmpty {
            directories.append("\(home)/.local/bin")
            directories.append("\(home)/bin")
        }
        directories.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ])

        var seen: Set<String> = []
        return directories.compactMap { rawDirectory in
            let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let standardized = URL(fileURLWithPath: trimmed, isDirectory: true)
                .standardizedFileURL
                .path
            guard seen.insert(standardized).inserted else { return nil }
            return standardized
        }
    }

    private func runtimeSearchPath(searchDirectories: [String]) -> String {
        searchDirectories
            .filter { !shouldSkipSearchDirectory($0) }
            .joined(separator: ":")
    }

    private func launchPlan(
        provider: AgentSessionProviderID,
        executableURL: URL,
        searchDirectories: [String]
    ) -> AgentSessionLaunchPlan {
        var launchEnvironment = environment
        launchEnvironment["PATH"] = runtimeSearchPath(searchDirectories: searchDirectories)
        return AgentSessionLaunchPlan(
            provider: provider,
            executableURL: executableURL,
            arguments: provider.launchArguments,
            environment: launchEnvironment
        )
    }

    private func resolvedConfiguredExecutableURL(for provider: AgentSessionProviderID) -> URL? {
        guard let rawPath = configuredExecutablePaths[provider]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        let candidateURL = URL(fileURLWithPath: rawPath, isDirectory: false).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: candidateURL.path),
              !isBundledProviderExecutable(candidateURL),
              !isKnownCmuxClaudeWrapper(candidateURL, provider: provider) else {
            return nil
        }
        return candidateURL
    }

    private func shouldSkipSearchDirectory(_ directory: String) -> Bool {
        let standardized = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
        if let bundleBin = bundleResourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .standardizedFileURL
            .path,
           standardized == bundleBin {
            return true
        }
        return false
    }

    private func isBundledProviderExecutable(_ url: URL) -> Bool {
        guard let resourcePath = bundleResourceURL?.standardizedFileURL.path else { return false }
        return url.standardizedFileURL.path.hasPrefix(resourcePath + "/")
    }

    private func isKnownCmuxClaudeWrapper(_ url: URL, provider: AgentSessionProviderID) -> Bool {
        guard provider == .claude,
              let data = fileManager.contents(atPath: url.path),
              let prefix = String(data: data.prefix(512), encoding: .utf8) else {
            return false
        }
        return prefix.contains("cmux claude wrapper - injects hooks and session tracking")
    }
}
