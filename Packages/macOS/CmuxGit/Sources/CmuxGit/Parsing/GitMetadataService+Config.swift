import Darwin
import Foundation

struct GitRemoteConfigSnapshot: Sendable {
    let remoteVOutput: String?
    let configURLs: [URL]
    let isComplete: Bool
    let watchFallbackURLs: [URL]
    let configStatuses: [String: GitFileStatus?]
}

struct GitRemoteURLRewrite: Sendable {
    let replacement: String
    let prefix: String
}

extension GitMetadataService {
    private struct GitConfigTraversalBudget {
        static let maximumFileCount = 512
        static let maximumMissingPathCount = 512
        static let maximumByteCount = 4 * 1024 * 1024
        static let maximumIncludeDepth = 32
        static let maximumDiscoveredRemoteURLCount = 4_096
        static let maximumHasConfigConditionCount = 1_024
        static let maximumHasConfigMatchOperationCount = 65_536
        static let maximumURLRewriteCount = 4_096
        static let maximumURLRewriteMatchOperationCount = 65_536

        var fileCount = 0
        var missingPathCount = 0
        var byteCount = 0
        var outputByteCount = 0
        var exceeded = false
        var fallbackURLs: [URL] = []
        var urlRewrites: [GitRemoteURLRewrite] = []
        var configStatuses: [String: GitFileStatus?] = [:]
        var worktreeConfigEnabled = false
        var discoveredRemoteURLs: Set<String> = []
        var effectiveRemoteLineIndexByName: [String: Int] = [:]
        var hasConfigConditionCount = 0
        var hasConfigMatchOperationCount = 0
        let commonConfigPaths: Set<String>
        let fileStatusReader: any GitFileStatusReading
        let filesystemLocalityReader: any GitFilesystemLocalityReading

        init(
            fileStatusReader: any GitFileStatusReading,
            commonConfigURL: URL,
            filesystemLocalityReader: any GitFilesystemLocalityReading
        ) {
            self.fileStatusReader = fileStatusReader
            self.filesystemLocalityReader = filesystemLocalityReader
            let standardized = commonConfigURL.standardizedFileURL
            var commonPaths = Set([standardized.path])
            if filesystemLocalityReader.isLocal(path: standardized.path) {
                let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL.path
                if filesystemLocalityReader.isLocal(path: resolved) {
                    commonPaths.insert(resolved)
                }
            }
            self.commonConfigPaths = commonPaths
        }

        mutating func recordFallback(_ url: URL) {
            guard fallbackURLs.count < 64 else { return }
            let normalized = url.standardizedFileURL
            guard !fallbackURLs.contains(normalized) else { return }
            fallbackURLs.append(normalized)
        }

        mutating func read(_ url: URL) -> String? {
            guard !exceeded else { return nil }
            let standardizedURL = url.standardizedFileURL
            guard standardizedURL.path == "/dev/null"
                    || filesystemLocalityReader.isLocal(path: standardizedURL.path) else {
                exceeded = true
                recordFallback(url)
                return nil
            }
            let readURL = url.resolvingSymlinksInPath()
            guard readURL.standardizedFileURL.path != "/dev/null" else {
                return ""
            }
            guard filesystemLocalityReader.isLocal(path: readURL.standardizedFileURL.path) else {
                exceeded = true
                recordFallback(url)
                return nil
            }
            let dependencyPaths = Set([
                url.standardizedFileURL.path,
                readURL.path
            ])
            let statusesBefore = dependencyPaths.reduce(into: [String: GitFileStatus?]()) { result, path in
                result.updateValue(fileStatusReader.status(atPath: path), forKey: path)
            }
            guard fileCount < Self.maximumFileCount else {
                exceeded = true
                recordFallback(url)
                return nil
            }
            let descriptor = Darwin.open(readURL.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else {
                let openError = errno
                for (path, fileStatus) in statusesBefore {
                    configStatuses.updateValue(fileStatus, forKey: path)
                }
                if openError == ENOENT || openError == ENOTDIR {
                    guard missingPathCount < Self.maximumMissingPathCount else {
                        exceeded = true
                        recordFallback(url)
                        return nil
                    }
                    missingPathCount += 1
                } else {
                    exceeded = true
                    recordFallback(url)
                }
                return nil
            }
            defer { Darwin.close(descriptor) }

            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_size >= 0,
                  status.st_size <= Int64(Self.maximumByteCount - byteCount) else {
                exceeded = true
                recordFallback(url)
                return nil
            }
            let remaining = Self.maximumByteCount - byteCount
            var data = Data()
            var readError: Int32?
            while data.count < remaining {
                let chunkSize = min(64 * 1024, remaining - data.count)
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                let readCount = buffer.withUnsafeMutableBytes { buffer in
                    Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                }
                if readCount == 0 {
                    break
                }
                if readCount < 0 {
                    if errno == EINTR {
                        continue
                    }
                    readError = errno
                    break
                }
                data.append(contentsOf: buffer.prefix(readCount))
            }
            guard Darwin.fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_size <= Int64(Self.maximumByteCount - byteCount),
                  readError == nil,
                  Int64(data.count) == status.st_size,
                  data.count <= remaining,
                  let config = String(data: data, encoding: .utf8) else {
                exceeded = true
                recordFallback(url)
                return nil
            }
            let statusesAfter = dependencyPaths.reduce(into: [String: GitFileStatus?]()) { result, path in
                result.updateValue(fileStatusReader.status(atPath: path), forKey: path)
            }
            guard statusesBefore == statusesAfter else {
                exceeded = true
                recordFallback(url)
                return nil
            }
            for (path, fileStatus) in statusesAfter {
                configStatuses.updateValue(fileStatus, forKey: path)
            }
            fileCount += 1
            byteCount += data.count
            return config
        }

        mutating func recordWorktreeConfigSetting(_ value: String) {
            if let enabled = GitMetadataService.gitConfigBooleanValue(value) {
                worktreeConfigEnabled = enabled
            }
        }

        func isCommonConfig(_ url: URL) -> Bool {
            let standardized = url.standardizedFileURL
            return commonConfigPaths.contains(standardized.path)
                || commonConfigPaths.contains(standardized.resolvingSymlinksInPath().path)
        }

        mutating func recordDiscoveredRemoteURL(_ remoteURL: String) {
            guard !remoteURL.isEmpty,
                  !discoveredRemoteURLs.contains(remoteURL) else {
                return
            }
            guard discoveredRemoteURLs.count < Self.maximumDiscoveredRemoteURLCount else {
                exceeded = true
                return
            }
            discoveredRemoteURLs.insert(remoteURL)
        }

        mutating func hasConfigMatches(pattern: String) -> Bool {
            guard !pattern.isEmpty, !exceeded else { return false }
            guard hasConfigConditionCount < Self.maximumHasConfigConditionCount else {
                exceeded = true
                return false
            }
            hasConfigConditionCount += 1
            let operationCount = discoveredRemoteURLs.count
            guard operationCount <= Self.maximumHasConfigMatchOperationCount
                    - hasConfigMatchOperationCount else {
                exceeded = true
                return false
            }
            hasConfigMatchOperationCount += operationCount
            let regexPattern = GitMetadataService.gitConfigGlobRegexPattern(pattern)
            guard let regex = try? NSRegularExpression(pattern: regexPattern) else {
                return discoveredRemoteURLs.contains {
                    fnmatch(pattern, $0, 0) == 0
                }
            }
            return discoveredRemoteURLs.contains { remoteURL in
                let range = NSRange(
                    remoteURL.startIndex..<remoteURL.endIndex,
                    in: remoteURL
                )
                return regex.firstMatch(in: remoteURL, range: range) != nil
            }
        }

        /// Collects raw remote URLs for Git's deferred hasconfig condition.
        ///
        /// Discovery follows matching non-hasconfig includes, so a hasconfig
        /// include cannot satisfy itself with a URL from its own gated file.
        mutating func discoverRemoteURLs(
            from url: URL,
            repository: ResolvedGitRepository,
            seenConfigPaths: inout Set<String>,
            depth: Int,
            homeDirectory: URL,
            isCommonConfigScope: Bool
        ) {
            guard depth <= Self.maximumIncludeDepth,
                  !exceeded else {
                return
            }
            let normalizedURL = url.standardizedFileURL
            guard seenConfigPaths.insert(normalizedURL.path).inserted,
                  let config = read(normalizedURL) else {
                return
            }

            var currentRemoteName: String?
            var allowsInclude = false
            var currentSectionIsExtensions = false
            for rawLine in config.components(separatedBy: .newlines) {
                let line = GitMetadataService.gitConfigLineRemovingInlineComment(rawLine)
                    .trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") && line.hasSuffix("]") {
                    currentRemoteName = GitMetadataService.gitConfigRemoteName(
                        fromSectionHeader: line
                    )
                    currentSectionIsExtensions = isCommonConfigScope
                        && line.lowercased() == "[extensions]"
                    if line.lowercased() == "[include]" {
                        allowsInclude = true
                    } else if let condition = GitMetadataService.gitConfigIncludeIfCondition(
                        fromSectionHeader: line
                    ) {
                        // The deferred hasconfig condition must not discover a
                        // URL from its own include. Other conditions can be
                        // evaluated normally during the bounded pre-scan.
                        allowsInclude = !condition.lowercased().hasPrefix("hasconfig:")
                            && GitMetadataService.gitConfigIncludeIfConditionMatches(
                                condition,
                                repository: repository,
                                configURL: normalizedURL,
                                discoveredRemoteURLs: discoveredRemoteURLs,
                                homeDirectory: homeDirectory
                            )
                    } else {
                        allowsInclude = false
                    }
                    continue
                }

                let parts = line.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                ).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if currentSectionIsExtensions,
                   parts.first?.lowercased() == "worktreeconfig" {
                    if let enabled = GitMetadataService.gitConfigBooleanValue(parts.count == 2 ? parts[1] : "true") {
                        worktreeConfigEnabled = enabled
                    }
                }
                if currentRemoteName != nil,
                   parts.count == 2,
                   parts[0].lowercased() == "url" {
                    let remoteURL = GitMetadataService.gitConfigUnquotedValue(parts[1])
                    recordDiscoveredRemoteURL(remoteURL)
                    continue
                }

                guard allowsInclude,
                      parts.count == 2,
                      parts[0].lowercased() == "path",
                      let includeURL = GitMetadataService.gitConfigIncludeURL(
                          fromPathValue: parts[1],
                          relativeTo: normalizedURL,
                          homeDirectory: homeDirectory
                      ) else {
                    continue
                }
                discoverRemoteURLs(
                    from: includeURL,
                    repository: repository,
                    seenConfigPaths: &seenConfigPaths,
                    depth: depth + 1,
                    homeDirectory: homeDirectory,
                    isCommonConfigScope: isCommonConfigScope
                )
            }
        }

        mutating func appendOutput(_ line: String) -> Bool {
            let byteCount = line.utf8.count
            guard outputByteCount <= Self.maximumByteCount - byteCount else {
                exceeded = true
                return false
            }
            outputByteCount += byteCount
            return true
        }

        mutating func recordURLRewrite(
            replacement: String,
            prefix: String
        ) {
            guard !exceeded else { return }
            guard urlRewrites.count < Self.maximumURLRewriteCount else {
                exceeded = true
                return
            }
            urlRewrites.append(
                GitRemoteURLRewrite(replacement: replacement, prefix: prefix)
            )
        }

        mutating func recordRemoteURL(
            remoteName: String,
            remoteURL: String,
            lines: inout [String]
        ) -> Bool {
            if remoteURL.isEmpty {
                if let index = effectiveRemoteLineIndexByName.removeValue(forKey: remoteName) {
                    lines[index] = ""
                }
                return true
            }
            guard effectiveRemoteLineIndexByName[remoteName] == nil else {
                return true
            }
            let line = "\(remoteName)\t\(remoteURL) (fetch)\n"
            guard appendOutput(line) else { return false }
            effectiveRemoteLineIndexByName[remoteName] = lines.endIndex
            lines.append(line)
            return true
        }
    }

    /// A synthesized `git remote -v`-style listing built by reading remote URLs
    /// straight from the reachable config files (no `git` process). `nil` when
    /// no remote URL is found.
    nonisolated static func gitRemoteVOutput(repository: ResolvedGitRepository) -> String? {
        let snapshot = gitRemoteConfigSnapshot(repository: repository)
        return snapshot.isComplete ? snapshot.remoteVOutput : nil
    }

    nonisolated static func gitRemoteConfigSnapshot(
        repository: ResolvedGitRepository,
        safetyConfiguration: GitMetadataSafetyConfiguration = GitMetadataSafetyConfiguration(),
        fileStatusReader: any GitFileStatusReading = SystemGitFileStatusReader(),
        filesystemLocalityReader: any GitFilesystemLocalityReading =
            SystemGitFilesystemLocalityReader(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GitRemoteConfigSnapshot {
        var lines: [String] = []
        var seenConfigPaths: Set<String> = []
        var configURLs: [URL] = []
        let commonConfigURL = URL(fileURLWithPath: repository.commonDirectory)
            .appendingPathComponent("config")
        let homeDirectory = gitHomeDirectory(environment: environment)
        let rootConfigURLs = gitRootConfigURLs(
            repository: repository,
            environment: environment
        )
        let hasRuntimeConfigOverrides: Bool = {
            if let rawCount = environment["GIT_CONFIG_COUNT"] {
                if !rawCount.isEmpty {
                    guard let count = Int(rawCount), count == 0 else { return true }
                }
                return environment.keys.contains {
                    $0.hasPrefix("GIT_CONFIG_KEY_")
                        || $0.hasPrefix("GIT_CONFIG_VALUE_")
                        || $0 == "GIT_CONFIG_PARAMETERS"
                }
            }
            return environment.keys.contains {
                $0.hasPrefix("GIT_CONFIG_KEY_")
                    || $0.hasPrefix("GIT_CONFIG_VALUE_")
                    || $0 == "GIT_CONFIG_PARAMETERS"
            }
        }()
        if hasRuntimeConfigOverrides {
            return GitRemoteConfigSnapshot(
                remoteVOutput: nil,
                configURLs: rootConfigURLs,
                isComplete: false,
                watchFallbackURLs: [],
                configStatuses: [:]
            )
        }
        var discoveryBudget = GitConfigTraversalBudget(
            fileStatusReader: fileStatusReader,
            commonConfigURL: commonConfigURL,
            filesystemLocalityReader: filesystemLocalityReader
        )
        var discoverySeenConfigPaths: Set<String> = []
        for configURL in rootConfigURLs {
            let isCommonConfigScope = discoveryBudget.isCommonConfig(configURL)
            discoveryBudget.discoverRemoteURLs(
                from: configURL,
                repository: repository,
                seenConfigPaths: &discoverySeenConfigPaths,
                depth: 0,
                homeDirectory: homeDirectory,
                isCommonConfigScope: isCommonConfigScope
            )
        }
        if discoveryBudget.worktreeConfigEnabled {
            discoveryBudget.discoverRemoteURLs(
                from: gitWorktreeConfigURL(repository: repository),
                repository: repository,
                seenConfigPaths: &discoverySeenConfigPaths,
                depth: 0,
                homeDirectory: homeDirectory,
                isCommonConfigScope: false
            )
        }
        let discoveryIsComplete = !discoveryBudget.exceeded
        let discoveredRemoteURLs = discoveryBudget.discoveredRemoteURLs
        var budget = GitConfigTraversalBudget(
            fileStatusReader: fileStatusReader,
            commonConfigURL: commonConfigURL,
            filesystemLocalityReader: filesystemLocalityReader
        )
        budget.discoveredRemoteURLs = discoveredRemoteURLs
        for configURL in rootConfigURLs {
            let isCommonConfigScope = budget.isCommonConfig(configURL)
            appendGitRemoteVLines(
                fromConfigURL: configURL,
                repository: repository,
                seenConfigPaths: &seenConfigPaths,
                configURLs: &configURLs,
                lines: &lines,
                budget: &budget,
                depth: 0,
                isCommonConfigScope: isCommonConfigScope,
                homeDirectory: homeDirectory,
                isHasConfigGated: false
            )
        }
        if budget.worktreeConfigEnabled {
            appendGitRemoteVLines(
                fromConfigURL: gitWorktreeConfigURL(repository: repository),
                repository: repository,
                seenConfigPaths: &seenConfigPaths,
                configURLs: &configURLs,
                lines: &lines,
                budget: &budget,
                depth: 0,
                isCommonConfigScope: false,
                homeDirectory: homeDirectory,
                isHasConfigGated: false
            )
        }
        let effectiveLines = lines.filter { !$0.isEmpty }
        let rawRemoteVOutput = effectiveLines.isEmpty ? nil : effectiveLines.joined()
        let remoteVOutput = rawRemoteVOutput.flatMap {
            rewrittenRemoteVOutput($0, rewrites: budget.urlRewrites)
        }
        return GitRemoteConfigSnapshot(
            remoteVOutput: remoteVOutput,
            configURLs: configURLs,
            isComplete: discoveryIsComplete
                && !budget.exceeded
                && (rawRemoteVOutput == nil || remoteVOutput != nil),
            watchFallbackURLs: budget.fallbackURLs,
            configStatuses: budget.configStatuses
        )
    }

    /// The Git config layers that can affect a repository's fetch remotes.
    nonisolated static func gitRootConfigURLs(
        repository: ResolvedGitRepository,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var urls = gitGlobalConfigURLs(environment: environment)
        urls.append(contentsOf: [
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("config"),
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("config"),
        ])
        return urls
    }

    /// Resolves standard system, global, and XDG Git config locations.
    private nonisolated static func gitGlobalConfigURLs(
        environment: [String: String]
    ) -> [URL] {
        var urls = gitSystemConfigURLs(environment: environment)
        if let global = environment["GIT_CONFIG_GLOBAL"] {
            if !global.isEmpty, global != "/dev/null" {
                urls.append(URL(fileURLWithPath: global))
            }
        } else {
            let home = gitHomeDirectory(environment: environment)
            let xdgHome: URL
            if let configuredXDGHome = environment["XDG_CONFIG_HOME"],
               !configuredXDGHome.isEmpty {
                xdgHome = URL(fileURLWithPath: configuredXDGHome)
            } else {
                xdgHome = home.appendingPathComponent(".config", isDirectory: true)
            }
            urls.append(xdgHome.appendingPathComponent("git/config"))
            urls.append(home.appendingPathComponent(".gitconfig"))
        }
        return urls
    }

    /// Resolves the system config path using Git's installation prefix.
    private nonisolated static func gitSystemConfigURLs(
        environment: [String: String]
    ) -> [URL] {
        let noSystemConfig: Bool
        if let rawValue = environment["GIT_CONFIG_NOSYSTEM"] {
            noSystemConfig = gitConfigBooleanValue(rawValue) ?? true
        } else {
            noSystemConfig = false
        }
        guard !noSystemConfig else { return [] }

        if let configured = environment["GIT_CONFIG_SYSTEM"] {
            guard !configured.isEmpty, configured != "/dev/null" else { return [] }
            return [URL(fileURLWithPath: configured)]
        }

        // Git chooses one installation prefix for the system config. Do not
        // replace that path with a different candidate merely because it
        // happens to exist on disk.
        if let execPath = environment["GIT_EXEC_PATH"],
           let prefix = gitInstallationPrefix(from: execPath) {
            return [
                URL(fileURLWithPath: prefix)
                    .appendingPathComponent("etc/gitconfig")
                    .standardizedFileURL
            ]
        }

        if let path = environment["PATH"] {
            for component in path.split(separator: ":", omittingEmptySubsequences: true) {
                let executable = URL(fileURLWithPath: String(component))
                    .appendingPathComponent("git")
                guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                    continue
                }
                for candidatePath in [executable.path, executable.resolvingSymlinksInPath().path] {
                    if let prefix = gitInstallationPrefix(from: candidatePath) {
                        return [
                            URL(fileURLWithPath: prefix)
                                .appendingPathComponent("etc/gitconfig")
                                .standardizedFileURL
                        ]
                    }
                }
            }
        }

        return [URL(fileURLWithPath: "/etc/gitconfig")]
    }

    /// Resolves Git's effective home directory for an environment snapshot.
    private nonisolated static func gitHomeDirectory(
        environment: [String: String]
    ) -> URL {
        if let configuredHome = environment["HOME"], !configuredHome.isEmpty {
            return URL(fileURLWithPath: configuredHome).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    /// The process home used by path planning when no HOME override exists.
    nonisolated static var processHomeDirectory: URL {
        gitHomeDirectory(environment: [:])
    }

    /// Derives an installation prefix from Git's executable or exec-root path.
    private nonisolated static func gitInstallationPrefix(from path: String) -> String? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        for suffix in ["/libexec/git-core", "/git-core"] {
            guard normalized.hasSuffix(suffix) else { continue }
            let prefix = String(normalized.dropLast(suffix.count))
            return prefix.isEmpty ? "/" : prefix
        }

        let executableURL = URL(fileURLWithPath: normalized)
        guard executableURL.lastPathComponent == "git",
              executableURL.deletingLastPathComponent().lastPathComponent == "bin" else {
            return nil
        }
        return executableURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    /// Parses Git's accepted boolean spellings, returning nil for invalid input.
    private nonisolated static func gitConfigBooleanValue(_ value: String) -> Bool? {
        switch gitConfigUnquotedValue(value).lowercased() {
        case "", "false", "no", "off", "0":
            return false
        case "true", "yes", "on", "1":
            return true
        default:
            return nil
        }
    }

    /// Returns the per-worktree config path for a resolved checkout.
    nonisolated static func gitWorktreeConfigURL(repository: ResolvedGitRepository) -> URL {
        URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("config.worktree")
    }

    /// Every config file reachable from the repository roots, following
    /// `include`/`includeIf` directives, de-duplicated by path.
    nonisolated static func gitConfigURLs(
        repository: ResolvedGitRepository,
        safetyConfiguration: GitMetadataSafetyConfiguration = GitMetadataSafetyConfiguration(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let snapshot = gitRemoteConfigSnapshot(
            repository: repository,
            safetyConfiguration: safetyConfiguration,
            fileStatusReader: SystemGitFileStatusReader(),
            environment: environment
        )
        return snapshot.configURLs + snapshot.watchFallbackURLs
    }

    /// Parses a single config string into `git remote -v` fetch lines (used by
    /// the test-only config entry point).
    nonisolated static func gitRemoteVLines(fromConfig config: String) -> [String] {
        var currentRemoteName: String?
        var lines: [String] = []
        var effectiveRemoteLineIndexByName: [String: Int] = [:]

        for rawLine in config.components(separatedBy: .newlines) {
            let line = gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentRemoteName = gitConfigRemoteName(fromSectionHeader: line)
                continue
            }

            guard let currentRemoteName else { continue }
            let parts = line.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0].lowercased() == "url" else {
                continue
            }
            let remoteURL = gitConfigUnquotedValue(parts[1])
            if remoteURL.isEmpty {
                if let index = effectiveRemoteLineIndexByName.removeValue(
                    forKey: currentRemoteName
                ) {
                    lines[index] = ""
                }
                continue
            }
            guard effectiveRemoteLineIndexByName[currentRemoteName] == nil else {
                continue
            }
            effectiveRemoteLineIndexByName[currentRemoteName] = lines.endIndex
            lines.append("\(currentRemoteName)\t\(remoteURL) (fetch)\n")
        }

        return lines.filter { !$0.isEmpty }
    }

    /// Appends `git remote -v` fetch lines from a config file (and its matching
    /// includes) into `lines`, guarding against include cycles via
    /// `seenConfigPaths`.
    private nonisolated static func appendGitRemoteVLines(
        fromConfigURL configURL: URL,
        repository: ResolvedGitRepository,
        seenConfigPaths: inout Set<String>,
        configURLs: inout [URL],
        lines: inout [String],
        budget: inout GitConfigTraversalBudget,
        depth: Int,
        isCommonConfigScope: Bool,
        homeDirectory: URL,
        isHasConfigGated: Bool
    ) {
        guard depth <= GitConfigTraversalBudget.maximumIncludeDepth,
              !budget.exceeded else {
            budget.recordFallback(configURL)
            budget.exceeded = true
            return
        }
        let configURL = configURL.standardizedFileURL
        guard configURL.path != "/dev/null" else { return }
        guard seenConfigPaths.insert(configURL.path).inserted else {
            return
        }
        guard configURLs.count < GitConfigTraversalBudget.maximumFileCount else {
            budget.recordFallback(configURL)
            budget.exceeded = true
            return
        }
        configURLs.append(configURL)
        guard let config = budget.read(configURL) else {
            return
        }

        var currentRemoteName: String?
        var currentURLRewriteReplacement: String?
        var currentSectionAllowsIncludePath = false
        var currentSectionIsExtensions = false
        var currentSectionIsHasConfig = false

        for rawLine in config.components(separatedBy: .newlines) {
            let line = gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentRemoteName = gitConfigRemoteName(fromSectionHeader: line)
                currentURLRewriteReplacement = gitConfigURLRewriteReplacement(
                    fromSectionHeader: line
                )
                currentSectionIsExtensions = isCommonConfigScope
                    && line.lowercased() == "[extensions]"
                if line.lowercased() == "[include]" {
                    currentSectionAllowsIncludePath = true
                    currentSectionIsHasConfig = false
                } else if let condition = gitConfigIncludeIfCondition(fromSectionHeader: line) {
                    let hasConfigPrefix = "hasconfig:remote.*.url:"
                    if condition.lowercased().hasPrefix(hasConfigPrefix) {
                        let pattern = String(condition.dropFirst(hasConfigPrefix.count))
                        currentSectionIsHasConfig = true
                        currentSectionAllowsIncludePath = budget.hasConfigMatches(
                            pattern: pattern
                        )
                    } else {
                        currentSectionIsHasConfig = false
                        currentSectionAllowsIncludePath = gitConfigIncludeIfConditionMatches(
                            condition,
                            repository: repository,
                            configURL: configURL,
                            homeDirectory: homeDirectory
                        )
                    }
                } else {
                    currentSectionAllowsIncludePath = false
                    currentSectionIsHasConfig = false
                }
                continue
            }

            let parts = line.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).map {
                $0.trimmingCharacters(in: .whitespaces)
            }

            if currentSectionIsExtensions,
               parts.first?.lowercased() == "worktreeconfig" {
                budget.recordWorktreeConfigSetting(parts.count == 2 ? parts[1] : "true")
            }

            if isHasConfigGated,
               currentRemoteName != nil,
               parts.count == 2,
               parts[0].lowercased() == "url" {
                // Git rejects remote URLs in files reached through hasconfig
                // to prevent those files from satisfying their own condition.
                budget.exceeded = true
                return
            }

            if let currentRemoteName,
               parts.count == 2,
               parts[0].lowercased() == "url" {
                let remoteURL = gitConfigUnquotedValue(parts[1])
                guard budget.recordRemoteURL(
                    remoteName: currentRemoteName,
                    remoteURL: remoteURL,
                    lines: &lines
                ) else { return }
                continue
            }

            if let replacement = currentURLRewriteReplacement,
               parts.count == 2,
               parts[0].lowercased() == "insteadof" {
                let prefix = gitConfigUnquotedValue(parts[1])
                if !prefix.isEmpty {
                    budget.recordURLRewrite(
                        replacement: replacement,
                        prefix: prefix
                    )
                }
                continue
            }

            guard currentSectionAllowsIncludePath,
                  parts.count == 2,
                  parts[0].lowercased() == "path",
                  let includeURL = gitConfigIncludeURL(
                      fromPathValue: parts[1],
                      relativeTo: configURL,
                      homeDirectory: homeDirectory
                  ) else {
                continue
            }
            appendGitRemoteVLines(
                fromConfigURL: includeURL,
                repository: repository,
                seenConfigPaths: &seenConfigPaths,
                configURLs: &configURLs,
                lines: &lines,
                budget: &budget,
                depth: depth + 1,
                isCommonConfigScope: isCommonConfigScope,
                homeDirectory: homeDirectory,
                isHasConfigGated: isHasConfigGated || currentSectionIsHasConfig
            )
        }
    }

    /// The config URLs included by `[include]`/`[includeIf "…"]` sections of a
    /// config string, resolved relative to `configURL`.
    nonisolated static func gitIncludedConfigURLs(
        fromConfig config: String,
        configURL: URL,
        repository: ResolvedGitRepository
    ) -> [URL] {
        var currentSectionAllowsPath = false
        var urls: [URL] = []

        for rawLine in config.components(separatedBy: .newlines) {
            let line = gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if line.lowercased() == "[include]" {
                    currentSectionAllowsPath = true
                } else if let condition = gitConfigIncludeIfCondition(fromSectionHeader: line) {
                    currentSectionAllowsPath = gitConfigIncludeIfConditionMatches(
                        condition,
                        repository: repository,
                        configURL: configURL
                    )
                } else {
                    currentSectionAllowsPath = false
                }
                continue
            }

            guard currentSectionAllowsPath else { continue }
            let parts = line.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2,
                  parts[0].lowercased() == "path",
                  let includeURL = gitConfigIncludeURL(
                    fromPathValue: parts[1],
                    relativeTo: configURL
                  ) else {
                continue
            }
            urls.append(includeURL)
        }

        return urls
    }

    /// Strips surrounding double quotes from a config value, honoring backslash
    /// escapes inside the quotes.
    nonisolated static func gitConfigUnquotedValue(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespaces)
        guard trimmedValue.first == "\"",
              trimmedValue.last == "\"",
              trimmedValue.count >= 2 else {
            return trimmedValue
        }

        var result = ""
        var isEscaped = false
        for character in trimmedValue.dropFirst().dropLast() {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            result.append(character)
        }

        if isEscaped {
            result.append("\\")
        }
        return result
    }

    /// Applies URL rewrites without allowing expanded output to exceed the
    /// bounded config traversal budget.
    private nonisolated static func rewrittenRemoteVOutput(
        _ output: String,
        rewrites: [GitRemoteURLRewrite]
    ) -> String? {
        guard !rewrites.isEmpty else { return output }
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.count <= GitConfigTraversalBudget.maximumURLRewriteMatchOperationCount
                / rewrites.count else {
            return nil
        }
        let orderedRewrites = rewrites.sorted {
            if $0.prefix.count != $1.prefix.count {
                return $0.prefix.count > $1.prefix.count
            }
            return $0.prefix < $1.prefix
        }
        var rewrittenOutput = ""
        var rewrittenByteCount = 0
        for line in lines {
            let parts = line.split(whereSeparator: \.isWhitespace)
            let rewrittenLine: String
            guard parts.count >= 3, parts[2] == "(fetch)" else {
                rewrittenLine = String(line) + "\n"
                let lineByteCount = rewrittenLine.utf8.count
                guard lineByteCount <= GitConfigTraversalBudget.maximumByteCount - rewrittenByteCount else {
                    return nil
                }
                rewrittenOutput.append(rewrittenLine)
                rewrittenByteCount += lineByteCount
                continue
            }
            let rawURL = String(parts[1])
            let rewrittenURL = orderedRewrites.first {
                rawURL.hasPrefix($0.prefix)
            }.map { $0.replacement + rawURL.dropFirst($0.prefix.count) } ?? rawURL
            rewrittenLine = "\(parts[0])\t\(rewrittenURL) (fetch)\n"
            let lineByteCount = rewrittenLine.utf8.count
            guard lineByteCount <= GitConfigTraversalBudget.maximumByteCount - rewrittenByteCount else {
                return nil
            }
            rewrittenOutput.append(rewrittenLine)
            rewrittenByteCount += lineByteCount
        }
        return rewrittenOutput
    }

    /// Removes a trailing inline `#`/`;` comment from a config line, ignoring
    /// `#`/`;` inside double-quoted strings.
    nonisolated static func gitConfigLineRemovingInlineComment(_ line: String) -> String {
        var result = ""
        var isInsideDoubleQuotedString = false
        var isEscaped = false
        var previousWasWhitespace = true

        for character in line {
            if isEscaped {
                result.append(character)
                isEscaped = false
                previousWasWhitespace = character.isWhitespace
                continue
            }

            if isInsideDoubleQuotedString && character == "\\" {
                result.append(character)
                isEscaped = true
                previousWasWhitespace = false
                continue
            }

            if character == "\"" {
                result.append(character)
                isInsideDoubleQuotedString.toggle()
                previousWasWhitespace = false
                continue
            }

            if !isInsideDoubleQuotedString,
               previousWasWhitespace,
               (character == "#" || character == ";") {
                break
            }

            result.append(character)
            previousWasWhitespace = character.isWhitespace
        }

        return result
    }

    /// The remote name from a `[remote "<name>"]` section header, or `nil`.
    /// The section name is case-insensitive per git; the quoted subsection
    /// (the remote name) is case-sensitive and extracted verbatim.
    nonisolated static func gitConfigRemoteName(fromSectionHeader header: String) -> String? {
        let prefix = "[remote \""
        let suffix = "\"]"
        guard header.count > prefix.count + suffix.count - 1,
              header.lowercased().hasPrefix(prefix),
              header.hasSuffix(suffix) else {
            return nil
        }
        let name = header.dropFirst(prefix.count).dropLast(suffix.count)
        return name.isEmpty ? nil : String(name)
    }

    /// The replacement prefix from a `[url "…"]` section header, or `nil`.
    private nonisolated static func gitConfigURLRewriteReplacement(
        fromSectionHeader header: String
    ) -> String? {
        let prefix = "[url \""
        let suffix = "\"]"
        guard header.count > prefix.count + suffix.count - 1,
              header.lowercased().hasPrefix(prefix),
              header.hasSuffix(suffix) else {
            return nil
        }
        let replacement = header.dropFirst(prefix.count).dropLast(suffix.count)
        return replacement.isEmpty ? nil : String(replacement)
    }

    /// The condition from an `[includeIf "<condition>"]` section header, or `nil`.
    /// The section name is case-insensitive per git; the condition is extracted
    /// verbatim (its own keyword prefixes are matched case-insensitively later).
    nonisolated static func gitConfigIncludeIfCondition(fromSectionHeader header: String) -> String? {
        let prefix = "[includeif \""
        let suffix = "\"]"
        guard header.count > prefix.count + suffix.count - 1,
              header.lowercased().hasPrefix(prefix),
              header.hasSuffix(suffix) else {
            return nil
        }
        let condition = header.dropFirst(prefix.count).dropLast(suffix.count)
        return condition.isEmpty ? nil : String(condition)
    }

    /// Resolves an include `path` value to a URL, expanding `~`, absolute, and
    /// config-relative forms.
    nonisolated static func gitConfigIncludeURL(
        fromPathValue pathValue: String,
        relativeTo configURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let path = gitConfigUnquotedValue(pathValue)
        guard !path.isEmpty else { return nil }
        if path == "~" {
            return homeDirectory.standardizedFileURL
        }
        if path.hasPrefix("~/") {
            let relativePath = String(path.dropFirst(2))
            return homeDirectory
                .appendingPathComponent(relativePath)
                .standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return configURL
            .deletingLastPathComponent()
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    /// Whether an `includeIf` condition (`gitdir:`, `gitdir/i:`, `onbranch:`)
    /// matches this repository. `configURL` anchors `./`-relative gitdir
    /// patterns to the directory containing the config file, per git.
    nonisolated static func gitConfigIncludeIfConditionMatches(
        _ condition: String,
        repository: ResolvedGitRepository,
        configURL: URL,
        discoveredRemoteURLs: Set<String> = [],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let lowercasedCondition = condition.lowercased()
        let hasConfigPrefix = "hasconfig:remote.*.url:"
        if lowercasedCondition.hasPrefix(hasConfigPrefix) {
            let pattern = String(condition.dropFirst(hasConfigPrefix.count))
            guard !pattern.isEmpty else { return false }
            let regexPattern = gitConfigGlobRegexPattern(pattern)
            guard let regex = try? NSRegularExpression(pattern: regexPattern) else {
                return discoveredRemoteURLs.contains {
                    fnmatch(pattern, $0, 0) == 0
                }
            }
            return discoveredRemoteURLs.contains { remoteURL in
                let range = NSRange(
                    remoteURL.startIndex..<remoteURL.endIndex,
                    in: remoteURL
                )
                return regex.firstMatch(in: remoteURL, range: range) != nil
            }
        }
        if lowercasedCondition.hasPrefix("gitdir/i:") {
            let pattern = String(condition.dropFirst("gitdir/i:".count))
            return gitConfigGitdirPatternMatches(
                pattern,
                repository: repository,
                caseInsensitive: true,
                configURL: configURL,
                homeDirectory: homeDirectory
            )
        }
        if lowercasedCondition.hasPrefix("gitdir:") {
            let pattern = String(condition.dropFirst("gitdir:".count))
            return gitConfigGitdirPatternMatches(
                pattern,
                repository: repository,
                caseInsensitive: false,
                configURL: configURL,
                homeDirectory: homeDirectory
            )
        }
        if lowercasedCondition.hasPrefix("onbranch:") {
            var pattern = String(condition.dropFirst("onbranch:".count))
            // Per git, an onbranch pattern ending in "/" matches the whole
            // branch hierarchy under it.
            if pattern.hasSuffix("/") {
                pattern.append("**")
            }
            guard let branch = gitBranchName(repository: repository) else { return false }
            return gitConfigGlobMatches(branch, pattern: pattern, caseInsensitive: false)
        }
        return false
    }

    /// Whether a `gitdir`/`gitdir/i` glob pattern matches any of the repository's
    /// directories, applying git's pattern-expansion rules: `~`/`~/` expand to
    /// the home directory, `./` is relative to the config file's directory, a
    /// pattern with no leading `~/`, `./`, or `/` gets `**/` prepended, and a
    /// trailing `/` appends `**` (the recursive-directory rule).
    nonisolated static func gitConfigGitdirPatternMatches(
        _ pattern: String,
        repository: ResolvedGitRepository,
        caseInsensitive: Bool,
        configURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let candidates = [
            repository.gitDirectory,
            repository.commonDirectory,
            repository.workTreeRoot,
        ].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        return gitConfigPathPatternMatches(
            pattern,
            candidates: candidates,
            caseInsensitive: caseInsensitive,
            configURL: configURL,
            homeDirectory: homeDirectory
        )
    }

    private nonisolated static func gitConfigPathPatternMatches(
        _ pattern: String,
        candidates: [String],
        caseInsensitive: Bool,
        configURL: URL,
        homeDirectory: URL
    ) -> Bool {
        let isRecursiveDirectoryPattern = pattern.hasSuffix("/")
        var expandedPattern = gitConfigExpandedPattern(
            pattern,
            configURL: configURL,
            homeDirectory: homeDirectory
        )
        if isRecursiveDirectoryPattern, !expandedPattern.hasSuffix("/") {
            expandedPattern.append("/")
        }
        if isRecursiveDirectoryPattern {
            expandedPattern.append("**")
        }
        for candidate in candidates {
            if gitConfigGlobMatches(candidate, pattern: expandedPattern, caseInsensitive: caseInsensitive) ||
                gitConfigGlobMatches(candidate + "/", pattern: expandedPattern, caseInsensitive: caseInsensitive) {
                return true
            }
        }
        return false
    }

    /// Expands an `includeIf` gitdir pattern per git's rules: `~`/`~/` to the
    /// home directory, `./` relative to the config file's directory, absolute
    /// paths standardized, and anything else prefixed with `**/` so a relative
    /// pattern matches at any depth.
    nonisolated static func gitConfigExpandedPattern(
        _ pattern: String,
        configURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if pattern == "~" {
            return homeDirectory.standardizedFileURL.path
        }
        if pattern.hasPrefix("~/") {
            let relativePath = String(pattern.dropFirst(2))
            return homeDirectory
                .appendingPathComponent(relativePath)
                .standardizedFileURL
                .path
        }
        if pattern.hasPrefix("./") {
            let relativePath = String(pattern.dropFirst(2))
            let base = configURL.deletingLastPathComponent()
            guard !relativePath.isEmpty else {
                return base.standardizedFileURL.path
            }
            // Keep glob metacharacters intact: anchor to the config directory
            // textually instead of routing the pattern through URL resolution.
            return base.standardizedFileURL.path + "/" + relativePath
        }
        if pattern.hasPrefix("/") {
            return URL(fileURLWithPath: pattern).standardizedFileURL.path
        }
        // Relative pattern: match at any depth.
        return "**/" + pattern
    }

    /// Matches a value against a git glob pattern, falling back to `fnmatch`
    /// when the translated regex cannot be compiled.
    nonisolated static func gitConfigGlobMatches(
        _ value: String,
        pattern: String,
        caseInsensitive: Bool
    ) -> Bool {
        let candidateValue = caseInsensitive ? value.lowercased() : value
        let candidatePattern = caseInsensitive ? pattern.lowercased() : pattern
        guard let regex = try? NSRegularExpression(
            pattern: gitConfigGlobRegexPattern(candidatePattern)
        ) else {
            return fnmatch(candidatePattern, candidateValue, 0) == 0
        }
        let range = NSRange(candidateValue.startIndex..<candidateValue.endIndex, in: candidateValue)
        return regex.firstMatch(in: candidateValue, range: range) != nil
    }

    /// Translates a git-style glob (`*`, `**`, `?`, `[…]`) into an anchored
    /// regular expression, treating `/` as a path separator.
    nonisolated static func gitConfigGlobRegexPattern(_ pattern: String) -> String {
        let characters = Array(pattern)
        var regex = "^"
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "*" {
                var starCount = 1
                while index + starCount < characters.count,
                      characters[index + starCount] == "*" {
                    starCount += 1
                }
                index += starCount

                if starCount >= 2 {
                    if index < characters.count, characters[index] == "/" {
                        index += 1
                        regex += "(?:.*/)?"
                    } else {
                        regex += ".*"
                    }
                } else {
                    regex += "[^/]*"
                }
                continue
            }

            if character == "?" {
                regex += "[^/]"
                index += 1
                continue
            }

            if character == "[" {
                let parsedClass = gitConfigGlobCharacterClass(characters, startIndex: index)
                if let parsedClass {
                    regex += parsedClass.regex
                    index = parsedClass.endIndex
                    continue
                }
            }

            regex += NSRegularExpression.escapedPattern(for: String(character))
            index += 1
        }

        regex += "$"
        return regex
    }

    /// Parses a `[…]` character class out of a glob into a regex class, or `nil`
    /// when the class is not terminated.
    nonisolated static func gitConfigGlobCharacterClass(
        _ characters: [Character],
        startIndex: Int
    ) -> (regex: String, endIndex: Int)? {
        guard startIndex < characters.count, characters[startIndex] == "[" else {
            return nil
        }

        var index = startIndex + 1
        guard index < characters.count else { return nil }

        var regex = "["
        if characters[index] == "!" {
            regex += "^"
            index += 1
        } else if characters[index] == "^" {
            regex += "\\^"
            index += 1
        }

        if index < characters.count, characters[index] == "]" {
            regex += "\\]"
            index += 1
        }

        var hasTerminator = false
        while index < characters.count {
            let character = characters[index]
            if character == "]" {
                hasTerminator = true
                index += 1
                break
            }
            switch character {
            case "\\":
                regex += "\\\\"
            case "[":
                regex += "\\["
            default:
                regex += String(character)
            }
            index += 1
        }

        guard hasTerminator else { return nil }
        regex += "]"
        return (regex, index)
    }
}
