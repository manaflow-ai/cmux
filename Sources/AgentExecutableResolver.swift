import Foundation

struct AgentExecutableResolver {
    var environment: [String: String]
    var fileManager: FileManager
    var bundleResourceURL: URL?
    var extraSearchDirectories: [String]
    var includeStandardSearchDirectories: Bool
    var configuredExecutablePaths: [AgentSessionProviderID: String]

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        extraSearchDirectories: [String] = [],
        includeStandardSearchDirectories: Bool = true,
        configuredExecutablePaths: [AgentSessionProviderID: String] = [:]
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.bundleResourceURL = bundleResourceURL
        self.extraSearchDirectories = extraSearchDirectories
        self.includeStandardSearchDirectories = includeStandardSearchDirectories
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
            guard !isKnownCmuxClaudeCommandShim(candidateURL, provider: provider) else { continue }
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
            directories.append(contentsOf: userRuntimeSearchDirectories(home: home))
        }
        if includeStandardSearchDirectories {
            directories.append(contentsOf: [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin"
            ])
        }

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

    private func userRuntimeSearchDirectories(home: String) -> [String] {
        var directories = [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.nvm/current/bin",
            "\(home)/.volta/bin",
            "\(home)/.fnm/current/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/bin"
        ]
        directories.append(contentsOf: nodeVersionBinDirectories(root: "\(home)/.nvm/versions/node", suffix: "bin"))
        directories.append(contentsOf: nodeVersionBinDirectories(root: "\(home)/Library/Application Support/fnm/node-versions", suffix: "installation/bin"))
        directories.append(contentsOf: nodeVersionBinDirectories(root: "\(home)/.local/share/fnm/node-versions", suffix: "installation/bin"))
        return directories
    }

    private func nodeVersionBinDirectories(root: String, suffix: String) -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let versionURLs = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return versionURLs
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted(by: nodeVersionURLSortPrecedes)
            .map { versionURL in
                suffix.split(separator: "/").reduce(versionURL) { partial, component in
                    partial.appendingPathComponent(String(component), isDirectory: true)
                }.path
            }
    }

    private func nodeVersionURLSortPrecedes(_ lhs: URL, _ rhs: URL) -> Bool {
        let comparison = lhs.lastPathComponent.compare(
            rhs.lastPathComponent,
            options: [.caseInsensitive, .numeric]
        )
        if comparison != .orderedSame {
            return comparison == .orderedDescending
        }
        return lhs.path > rhs.path
    }

    private func runtimeSearchPath(
        searchDirectories: [String],
        includingExecutableAt executableURL: URL
    ) -> String {
        let executableDirectory = executableURL
            .standardizedFileURL
            .deletingLastPathComponent()
            .path
        var runtimeDirectories = searchDirectories.filter { !shouldSkipSearchDirectory($0) }
        runtimeDirectories.removeAll { $0 == executableDirectory }
        runtimeDirectories.insert(executableDirectory, at: 0)
        return runtimeDirectories.joined(separator: ":")
    }

    private func launchPlan(
        provider: AgentSessionProviderID,
        executableURL: URL,
        searchDirectories: [String]
    ) -> AgentSessionLaunchPlan {
        var launchEnvironment = environment
        launchEnvironment["PATH"] = runtimeSearchPath(
            searchDirectories: searchDirectories,
            includingExecutableAt: executableURL
        )
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
              !isKnownCmuxClaudeCommandShim(candidateURL, provider: provider),
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
        if Self.isCmuxAppBundleResourceBinDirectory(standardized) {
            return true
        }
        return false
    }

    private func isKnownCmuxClaudeCommandShim(_ url: URL, provider: AgentSessionProviderID) -> Bool {
        guard provider == .claude else { return false }
        let candidatePath = url.standardizedFileURL.path
        if let shimPath = environment["CMUX_CLAUDE_WRAPPER_SHIM"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shimPath.isEmpty,
           candidatePath == URL(fileURLWithPath: shimPath, isDirectory: false).standardizedFileURL.path {
            return true
        }

        let shimRoots: [String?] = [
            environment["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"],
            URL(fileURLWithPath: environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-cli-shims", isDirectory: true)
                .standardizedFileURL
                .path,
            "/tmp/cmux-cli-shims",
        ]
        for shimRoot in shimRoots {
            guard let shimRoot = shimRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !shimRoot.isEmpty else { continue }
            let standardizedRoot = URL(fileURLWithPath: shimRoot, isDirectory: true)
                .standardizedFileURL
                .path
            if candidatePath.hasPrefix(standardizedRoot + "/") {
                return true
            }
        }
        return false
    }

    private func isBundledProviderExecutable(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if Self.isCmuxAppBundleResourceBinChild(path) {
            return true
        }
        guard let resourcePath = bundleResourceURL?.standardizedFileURL.path else { return false }
        return path.hasPrefix(resourcePath + "/")
    }

    private func isKnownCmuxClaudeWrapper(_ url: URL, provider: AgentSessionProviderID) -> Bool {
        guard provider == .claude,
              let data = fileManager.contents(atPath: url.path),
              let prefix = String(data: data.prefix(512), encoding: .utf8) else {
            return false
        }
        return prefix.contains("cmux claude wrapper - injects hooks and session tracking")
    }

    private static func isCmuxAppBundleResourceBinDirectory(_ path: String) -> Bool {
        cmuxAppBundleResourceBinComponentIndex(path).map { index in
            URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.pathComponents.count == index + 4
        } ?? false
    }

    private static func isCmuxAppBundleResourceBinChild(_ path: String) -> Bool {
        cmuxAppBundleResourceBinComponentIndex(path).map { index in
            URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.pathComponents.count > index + 4
        } ?? false
    }

    private static func cmuxAppBundleResourceBinComponentIndex(_ path: String) -> Int? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count >= 4 else { return nil }
        for index in components.indices {
            guard components[index].hasSuffix(".app"),
                  components[index].lowercased().contains("cmux"),
                  components.indices.contains(index + 3),
                  components[index + 1] == "Contents",
                  components[index + 2] == "Resources",
                  components[index + 3] == "bin" else {
                continue
            }
            return index
        }
        return nil
    }
}
