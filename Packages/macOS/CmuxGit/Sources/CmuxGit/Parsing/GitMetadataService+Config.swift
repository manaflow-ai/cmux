import Foundation

extension GitMetadataService {
    /// A synthesized `git remote -v`-style listing built by reading remote URLs
    /// straight from the reachable config files (no `git` process). `nil` when
    /// no remote URL is found.
    public nonisolated func gitRemoteVOutput(repository: ResolvedGitRepository) -> String? {
        var lines: [String] = []
        var seenConfigPaths: Set<String> = []
        for configURL in gitRootConfigURLs(repository: repository) {
            appendGitRemoteVLines(
                fromConfigURL: configURL,
                repository: repository,
                seenConfigPaths: &seenConfigPaths,
                lines: &lines
            )
        }
        return lines.isEmpty ? nil : lines.joined()
    }

    /// The repository's top-level config files (common directory, then git
    /// directory).
    nonisolated func gitRootConfigURLs(repository: ResolvedGitRepository) -> [URL] {
        [
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("config"),
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("config"),
        ]
    }

    /// Every config file reachable from the repository roots, following
    /// `include`/`includeIf` directives, de-duplicated by path.
    nonisolated func gitConfigURLs(repository: ResolvedGitRepository) -> [URL] {
        var urls: [URL] = []
        var pendingURLs = gitRootConfigURLs(repository: repository)
        var seenConfigPaths: Set<String> = []

        while !pendingURLs.isEmpty {
            let configURL = pendingURLs.removeFirst().standardizedFileURL
            let path = configURL.path
            guard seenConfigPaths.insert(path).inserted else { continue }
            urls.append(configURL)
            guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
                continue
            }
            pendingURLs.append(
                contentsOf: gitIncludedConfigURLs(
                    fromConfig: config,
                    configURL: configURL,
                    repository: repository
                )
            )
        }

        return urls
    }

    /// Parses a single config string into `git remote -v` fetch lines (used by
    /// the test-only config entry point).
    nonisolated func gitRemoteVLines(fromConfig config: String) -> [String] {
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
    nonisolated func appendGitRemoteVLines(
        fromConfigURL configURL: URL,
        repository: ResolvedGitRepository,
        seenConfigPaths: inout Set<String>,
        lines: inout [String]
    ) {
        let configURL = configURL.standardizedFileURL
        guard seenConfigPaths.insert(configURL.path).inserted,
              let config = try? String(contentsOf: configURL, encoding: .utf8) else {
            return
        }

        var currentRemoteName: String?
        var currentSectionAllowsIncludePath = false

        for rawLine in config.components(separatedBy: .newlines) {
            let line = gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentRemoteName = gitConfigRemoteName(fromSectionHeader: line)
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
                lines.append("\(currentRemoteName)\t\(remoteURL) (fetch)\n")
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
                lines: &lines
            )
        }
    }

    /// The config URLs included by `[include]`/`[includeIf "…"]` sections of a
    /// config string, resolved relative to `configURL`.
    nonisolated func gitIncludedConfigURLs(
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
    nonisolated func gitConfigUnquotedValue(_ value: String) -> String {
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

    /// Removes a trailing inline `#`/`;` comment from a config line, ignoring
    /// `#`/`;` inside double-quoted strings.
    nonisolated func gitConfigLineRemovingInlineComment(_ line: String) -> String {
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
    nonisolated func gitConfigRemoteName(fromSectionHeader header: String) -> String? {
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

    /// The condition from an `[includeIf "<condition>"]` section header, or `nil`.
    /// The section name is case-insensitive per git; the condition is extracted
    /// verbatim (its own keyword prefixes are matched case-insensitively later).
    nonisolated func gitConfigIncludeIfCondition(fromSectionHeader header: String) -> String? {
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
    nonisolated func gitConfigIncludeURL(
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
    nonisolated func gitConfigIncludeIfConditionMatches(
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
            guard let branch = Self.gitBranchName(repository: repository) else { return false }
            return gitConfigGlobMatches(branch, pattern: pattern, caseInsensitive: false)
        }
        return false
    }

    /// Whether a `gitdir`/`gitdir/i` glob pattern matches any of the repository's
    /// directories, applying git's pattern-expansion rules: `~`/`~/` expand to
    /// the home directory, `./` is relative to the config file's directory, a
    /// pattern with no leading `~/`, `./`, or `/` gets `**/` prepended, and a
    /// trailing `/` appends `**` (the recursive-directory rule).
    nonisolated func gitConfigGitdirPatternMatches(
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
    nonisolated func gitConfigExpandedPattern(_ pattern: String, configURL: URL) -> String {
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
    nonisolated func gitConfigGlobMatches(
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
    nonisolated func gitConfigGlobRegexPattern(_ pattern: String) -> String {
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
    nonisolated func gitConfigGlobCharacterClass(
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
