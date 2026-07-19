import CmuxSettings
import Darwin
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
        guard let claudePath = AgentIntegrationSettingsStore(defaults: defaults).customClaudePath else {
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

/// The executable lookup inputs derived from the same argv and environment policy
/// used to render a resume or fork command. Only PATH affects executable lookup,
/// so keeping that value instead of the complete process environment makes this a
/// compact cache key during large session restores.
struct AgentCommandExecutionDescriptor: Hashable, Sendable {
    let executable: String
    let searchPath: String?
    let workingDirectory: String?
    let fallbackExecutables: [String]

    init(
        executable: String,
        searchPath: String?,
        workingDirectory: String?,
        fallbackExecutables: [String] = []
    ) {
        self.executable = executable
        self.searchPath = searchPath
        self.workingDirectory = workingDirectory
        self.fallbackExecutables = fallbackExecutables
    }
}

struct AgentCommandExecutableResolution: Hashable, Sendable {
    let descriptor: AgentCommandExecutionDescriptor
    let lookupPath: String
    let realPath: String
    let cachePart: String
    let watchDirectories: [String]
}

struct AgentCommandExecutableLookup: Sendable, Equatable {
    let resolution: AgentCommandExecutableResolution?
    let candidateLookupPath: String?
    let watchDirectories: [String]
}

/// Resolves generated agent commands without invoking a shell. One resolver is
/// shared across a restore batch so equal command/PATH/cwd triples are statted once.
final class AgentCommandExecutableResolver {
    private enum CachedLookup {
        case value(AgentCommandExecutableLookup)
    }

    private var lookupsByDescriptor: [AgentCommandExecutionDescriptor: CachedLookup] = [:]

    func lookup(_ descriptor: AgentCommandExecutionDescriptor) -> AgentCommandExecutableLookup {
        if case .value(let cached)? = lookupsByDescriptor[descriptor] {
            return cached
        }
        let lookup = Self.lookupUncached(descriptor)
        lookupsByDescriptor[descriptor] = .value(lookup)
        return lookup
    }

    func resolve(_ descriptor: AgentCommandExecutionDescriptor) -> AgentCommandExecutableResolution? {
        lookup(descriptor).resolution
    }

    static func revalidate(_ resolution: AgentCommandExecutableResolution) -> Bool {
        lookupUncached(resolution.descriptor).resolution == resolution
    }

    static func lookupUncached(
        _ descriptor: AgentCommandExecutionDescriptor
    ) -> AgentCommandExecutableLookup {
        if !descriptor.fallbackExecutables.isEmpty {
            var firstCandidate: String?
            var watchDirectories: [String] = []
            var seenWatchDirectories = Set<String>()
            for executable in [descriptor.executable] + descriptor.fallbackExecutables {
                let candidateDescriptor = AgentCommandExecutionDescriptor(
                    executable: executable,
                    searchPath: descriptor.searchPath,
                    workingDirectory: descriptor.workingDirectory
                )
                let lookup = lookupUncached(candidateDescriptor)
                firstCandidate = firstCandidate ?? lookup.candidateLookupPath
                for directory in lookup.watchDirectories
                where seenWatchDirectories.insert(directory).inserted {
                    watchDirectories.append(directory)
                }
                if let resolution = lookup.resolution {
                    return AgentCommandExecutableLookup(
                        resolution: AgentCommandExecutableResolution(
                            descriptor: descriptor,
                            lookupPath: resolution.lookupPath,
                            realPath: resolution.realPath,
                            cachePart: resolution.cachePart,
                            watchDirectories: watchDirectories
                        ),
                        candidateLookupPath: resolution.lookupPath,
                        watchDirectories: watchDirectories
                    )
                }
            }
            return AgentCommandExecutableLookup(
                resolution: nil,
                candidateLookupPath: firstCandidate,
                watchDirectories: watchDirectories
            )
        }
        let normalizedWorkingDirectory = descriptor.workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = normalizedWorkingDirectory.flatMap { directory in
            directory.hasPrefix("/") ? URL(fileURLWithPath: directory, isDirectory: true) : nil
        }

        func absolutePath(_ path: String) -> String? {
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
            }
            guard let baseURL else { return nil }
            return URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL.path
        }

        if descriptor.executable.contains("/") {
            guard let candidate = absolutePath(descriptor.executable) else {
                // A cwd-ignored command runs in the destination terminal's
                // startup directory, not cmux's process directory. Relative
                // executable lookup is therefore unknowable here and must not
                // be authorized against an unrelated local file.
                return AgentCommandExecutableLookup(
                    resolution: nil,
                    candidateLookupPath: nil,
                    watchDirectories: []
                )
            }
            let watchDirectories = [URL(fileURLWithPath: candidate).deletingLastPathComponent().path]
            return AgentCommandExecutableLookup(
                resolution: executableResolution(
                    descriptor: descriptor,
                    lookupPath: candidate,
                    watchDirectories: watchDirectories
                ),
                candidateLookupPath: candidate,
                watchDirectories: watchDirectories
            )
        }

        let rawSearchPath = descriptor.searchPath ?? "/usr/bin:/bin"
        let searchDirectories = rawSearchPath.isEmpty
            ? [""]
            : rawSearchPath.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var firstCandidate: String?
        var watchDirectories: [String] = []
        var seenWatchDirectories = Set<String>()
        for directory in searchDirectories {
            let relativeCandidate = (directory.isEmpty ? "." : directory) + "/" + descriptor.executable
            guard let candidate = absolutePath(relativeCandidate) else {
                // Empty and relative PATH components are evaluated against the
                // shell's cwd in order. If that cwd is unknown, even a later
                // absolute match is ambiguous because an earlier candidate may
                // win when the command actually runs.
                return AgentCommandExecutableLookup(
                    resolution: nil,
                    candidateLookupPath: firstCandidate,
                    watchDirectories: watchDirectories
                )
            }
            firstCandidate = firstCandidate ?? candidate
            let watchDirectory = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
            if seenWatchDirectories.insert(watchDirectory).inserted {
                watchDirectories.append(watchDirectory)
            }
            if let resolution = executableResolution(
                descriptor: descriptor,
                lookupPath: candidate,
                watchDirectories: watchDirectories
            ) {
                return AgentCommandExecutableLookup(
                    resolution: resolution,
                    candidateLookupPath: candidate,
                    watchDirectories: watchDirectories
                )
            }
        }
        return AgentCommandExecutableLookup(
            resolution: nil,
            candidateLookupPath: firstCandidate,
            watchDirectories: watchDirectories
        )
    }

    private static func executableResolution(
        descriptor: AgentCommandExecutionDescriptor,
        lookupPath: String,
        watchDirectories: [String]
    ) -> AgentCommandExecutableResolution? {
        var status = stat()
        guard stat(lookupPath, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              Darwin.access(lookupPath, X_OK) == 0 else {
            return nil
        }
        let realPath = Darwin.realpath(lookupPath, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? lookupPath
        let cachePart = [
            realPath,
            "dev=\(status.st_dev)",
            "ino=\(status.st_ino)",
            "mode=\(status.st_mode)",
            "size=\(status.st_size)",
            "mtime=\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)",
            "ctime=\(status.st_ctimespec.tv_sec).\(status.st_ctimespec.tv_nsec)",
        ].joined(separator: ":")
        return AgentCommandExecutableResolution(
            descriptor: descriptor,
            lookupPath: lookupPath,
            realPath: realPath,
            cachePart: cachePart,
            watchDirectories: watchDirectories
        )
    }
}
