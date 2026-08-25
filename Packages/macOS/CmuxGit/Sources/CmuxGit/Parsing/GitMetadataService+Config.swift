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
        static let maximumByteCount = 4 * 1024 * 1024
        static let maximumIncludeDepth = 32

        var fileCount = 0
        var byteCount = 0
        var outputByteCount = 0
        var exceeded = false
        var fallbackURLs: [URL] = []
        var urlRewrites: [GitRemoteURLRewrite] = []
        var configStatuses: [String: GitFileStatus?] = [:]
        let fileStatusReader: any GitFileStatusReading

        init(fileStatusReader: any GitFileStatusReading) {
            self.fileStatusReader = fileStatusReader
        }

        mutating func recordFallback(_ url: URL) {
            guard fallbackURLs.count < 64 else { return }
            let normalized = url.standardizedFileURL
            guard !fallbackURLs.contains(normalized) else { return }
            fallbackURLs.append(normalized)
        }

        mutating func read(_ url: URL) -> String? {
            guard !exceeded else { return nil }
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            let readURL = url.resolvingSymlinksInPath()
            guard fileCount < Self.maximumFileCount,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: readURL.path),
                  let type = attributes[.type] as? FileAttributeType,
                  type == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value >= 0,
                  size.int64Value <= Int64(Self.maximumByteCount - byteCount) else {
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
            let descriptor = Darwin.open(readURL.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { return nil }
            defer { Darwin.close(descriptor) }

            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG else {
                exceeded = true
                recordFallback(url)
                return nil
            }
            let remaining = Self.maximumByteCount - byteCount
            var data = Data()
            while data.count < remaining {
                let chunkSize = min(64 * 1024, remaining - data.count)
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                let readCount = buffer.withUnsafeMutableBytes { buffer in
                    Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                }
                guard readCount > 0 else { break }
                data.append(contentsOf: buffer.prefix(readCount))
            }
            guard Darwin.fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_size <= Int64(Self.maximumByteCount - byteCount),
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

        mutating func appendOutput(_ line: String) -> Bool {
            let byteCount = line.utf8.count
            guard outputByteCount <= Self.maximumByteCount - byteCount else {
                exceeded = true
                return false
            }
            outputByteCount += byteCount
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
        fileStatusReader: any GitFileStatusReading = SystemGitFileStatusReader()
    ) -> GitRemoteConfigSnapshot {
        var lines: [String] = []
        var seenConfigPaths: Set<String> = []
        var configURLs: [URL] = []
        var budget = GitConfigTraversalBudget(fileStatusReader: fileStatusReader)
        for configURL in gitRootConfigURLs(repository: repository) {
            appendGitRemoteVLines(
                fromConfigURL: configURL,
                repository: repository,
                seenConfigPaths: &seenConfigPaths,
                configURLs: &configURLs,
                lines: &lines,
                budget: &budget,
                depth: 0
            )
        }
        return GitRemoteConfigSnapshot(
            remoteVOutput: lines.isEmpty
                ? nil
                : rewrittenRemoteVOutput(lines.joined(), rewrites: budget.urlRewrites),
            configURLs: configURLs,
            isComplete: !budget.exceeded,
            watchFallbackURLs: budget.fallbackURLs,
            configStatuses: budget.configStatuses
        )
    }

    /// The Git config layers that can affect a repository's fetch remotes.
    nonisolated static func gitRootConfigURLs(repository: ResolvedGitRepository) -> [URL] {
        var urls = gitGlobalConfigURLs()
        urls.append(contentsOf: [
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("config"),
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("config"),
        ])
        let worktreeConfig = URL(fileURLWithPath: repository.gitDirectory)
            .appendingPathComponent("config.worktree")
        if FileManager.default.fileExists(atPath: worktreeConfig.path) {
            urls.append(worktreeConfig)
        }
        return urls
    }

    /// Resolves standard system, global, and XDG Git config locations.
    private nonisolated static func gitGlobalConfigURLs() -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        var urls: [URL] = []
        if environment["GIT_CONFIG_NOSYSTEM"] == nil {
            let systemPath = environment["GIT_CONFIG_SYSTEM"] ?? "/etc/gitconfig"
            if systemPath != "/dev/null" {
                urls.append(URL(fileURLWithPath: systemPath))
            }
        }
        if let global = environment["GIT_CONFIG_GLOBAL"] {
            if global != "/dev/null" {
                urls.append(URL(fileURLWithPath: global))
            }
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            urls.append(home.appendingPathComponent(".gitconfig"))
            let xdgHome = environment["XDG_CONFIG_HOME"]
                .map(URL.init(fileURLWithPath:))
                ?? home.appendingPathComponent(".config", isDirectory: true)
            urls.append(xdgHome.appendingPathComponent("git/config"))
        }
        return urls
    }

    /// Every config file reachable from the repository roots, following
    /// `include`/`includeIf` directives, de-duplicated by path.
    nonisolated static func gitConfigURLs(
        repository: ResolvedGitRepository,
        safetyConfiguration: GitMetadataSafetyConfiguration = GitMetadataSafetyConfiguration()
    ) -> [URL] {
        let snapshot = gitRemoteConfigSnapshot(
            repository: repository,
            safetyConfiguration: safetyConfiguration,
            fileStatusReader: SystemGitFileStatusReader()
        )
        return snapshot.configURLs + snapshot.watchFallbackURLs
    }

    /// Parses a single config string into `git remote -v` fetch lines (used by
    /// the test-only config entry point).
    nonisolated static func gitRemoteVLines(fromConfig config: String) -> [String] {
        var currentRemoteName: String?
        var lines: [String] = []

        for rawLine in config.components(separatedBy: .newlines) {
            let line = gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentRemoteName = gitConfigRemoteName(fromSectionHeader: line)
                continue
            }

            guard let currentRemoteName else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0].lowercased() == "url" else {
                continue
            }
            let remoteURL = gitConfigUnquotedValue(parts[1])
            guard !remoteURL.isEmpty else {
                continue
            }
            lines.append("\(currentRemoteName)\t\(remoteURL) (fetch)\n")
        }

        return lines
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
        depth: Int
    ) {
        guard depth <= GitConfigTraversalBudget.maximumIncludeDepth,
              !budget.exceeded else {
            budget.recordFallback(configURL)
            budget.exceeded = true
            return
        }
        let configURL = configURL.standardizedFileURL
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

        for rawLine in config.components(separatedBy: .newlines) {
            let line = gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentRemoteName = gitConfigRemoteName(fromSectionHeader: line)
                currentURLRewriteReplacement = gitConfigURLRewriteReplacement(
                    fromSectionHeader: line
                )
                if line.lowercased() == "[include]" {
                    currentSectionAllowsIncludePath = true
                } else if let condition = gitConfigIncludeIfCondition(fromSectionHeader: line) {
                    currentSectionAllowsIncludePath = gitConfigIncludeIfConditionMatches(
                        condition,
                        repository: repository,
                        configURL: configURL
                    )
                } else {
                    currentSectionAllowsIncludePath = false
                }
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }

            if let currentRemoteName,
               parts.count == 2,
               parts[0].lowercased() == "url" {
                let remoteURL = gitConfigUnquotedValue(parts[1])
                guard !remoteURL.isEmpty else {
                    continue
                }
                let line = "\(currentRemoteName)\t\(remoteURL) (fetch)\n"
                guard budget.appendOutput(line) else { return }
                lines.append(line)
                continue
            }

            if let replacement = currentURLRewriteReplacement,
               parts.count == 2,
               parts[0].lowercased() == "insteadof" {
                let prefix = gitConfigUnquotedValue(parts[1])
                if !prefix.isEmpty {
                    budget.urlRewrites.append(
                        GitRemoteURLRewrite(replacement: replacement, prefix: prefix)
                    )
                }
                continue
            }

            guard currentSectionAllowsIncludePath,
                  parts.count == 2,
                  parts[0].lowercased() == "path",
                  let includeURL = gitConfigIncludeURL(
                      fromPathValue: parts[1],
                      relativeTo: configURL
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
                depth: depth + 1
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
            let parts = line.split(separator: "=", maxSplits: 1).map {
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

    private nonisolated static func rewrittenRemoteVOutput(
        _ output: String,
        rewrites: [GitRemoteURLRewrite]
    ) -> String {
        guard !rewrites.isEmpty else { return output }
        let orderedRewrites = rewrites.sorted {
            if $0.prefix.count != $1.prefix.count {
                return $0.prefix.count > $1.prefix.count
            }
            return $0.prefix < $1.prefix
        }
        return output.split(whereSeparator: \.isNewline).map { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3, parts[2] == "(fetch)" else {
                return String(line) + "\n"
            }
            let rawURL = String(parts[1])
            let rewrittenURL = orderedRewrites.first {
                rawURL.hasPrefix($0.prefix)
            }.map { $0.replacement + rawURL.dropFirst($0.prefix.count) } ?? rawURL
            return "\(parts[0])\t\(rewrittenURL) (fetch)\n"
        }.joined()
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
        relativeTo configURL: URL
    ) -> URL? {
        let path = gitConfigUnquotedValue(pathValue)
        guard !path.isEmpty else { return nil }
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        }
        if path.hasPrefix("~/") {
            let relativePath = String(path.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser
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
        configURL: URL
    ) -> Bool {
        let lowercasedCondition = condition.lowercased()
        if lowercasedCondition.hasPrefix("gitdir/i:") {
            let pattern = String(condition.dropFirst("gitdir/i:".count))
            return gitConfigGitdirPatternMatches(
                pattern, repository: repository, caseInsensitive: true, configURL: configURL
            )
        }
        if lowercasedCondition.hasPrefix("gitdir:") {
            let pattern = String(condition.dropFirst("gitdir:".count))
            return gitConfigGitdirPatternMatches(
                pattern, repository: repository, caseInsensitive: false, configURL: configURL
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
        configURL: URL
    ) -> Bool {
        let isRecursiveDirectoryPattern = pattern.hasSuffix("/")
        var expandedPattern = gitConfigExpandedPattern(pattern, configURL: configURL)
        if isRecursiveDirectoryPattern, !expandedPattern.hasSuffix("/") {
            expandedPattern.append("/")
        }
        if isRecursiveDirectoryPattern {
            expandedPattern.append("**")
        }
        let candidates = [
            repository.gitDirectory,
            repository.commonDirectory,
            repository.workTreeRoot,
        ].map { URL(fileURLWithPath: $0).standardizedFileURL.path }

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
    nonisolated static func gitConfigExpandedPattern(_ pattern: String, configURL: URL) -> String {
        if pattern == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        }
        if pattern.hasPrefix("~/") {
            let relativePath = String(pattern.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser
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
