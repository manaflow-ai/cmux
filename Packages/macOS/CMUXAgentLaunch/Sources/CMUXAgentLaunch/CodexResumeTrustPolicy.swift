import Darwin
import Foundation

/// Keeps unattended Codex resume non-interactive without granting project trust.
///
/// Codex prompts when the active working directory and its repository root have
/// no explicit `projects.<path>.trust_level` decision. A cmux auto-resume cannot
/// answer that prompt safely, so an undecided resume receives an invocation-only
/// `untrusted` override. Explicit trusted or untrusted decisions in the user's
/// config, and explicit resume-scoped launch overrides, remain authoritative.
public struct CodexResumeTrustPolicy: Sendable, Equatable {
    public init() {}

    /// Returns the `-c key=value` pair needed to skip Codex's directory-trust
    /// prompt safely, or an empty array when this is not a resume or Codex can
    /// already resolve an explicit decision.
    public func undecidedProjectOverride(
        arguments: [String],
        currentDirectory: String,
        repositoryRoot: String?,
        userConfigContents: String?
    ) -> [String] {
        guard let resumeIndex = resumeSubcommandIndex(arguments) else { return [] }

        let currentDirectory = effectiveWorkingDirectory(
            arguments: arguments,
            currentDirectory: currentDirectory
        )
        guard let currentDirectory else { return [] }
        let candidates = Set(
            [currentDirectory, normalizedAbsolutePath(repositoryRoot)]
                .compactMap { $0 }
                .map(canonicalProjectPath)
        )

        let resumeArguments = Array(arguments[arguments.index(after: resumeIndex)...])
        if argumentsContainProjectTrustDecision(resumeArguments, candidates: candidates)
            || userConfigContainsProjectTrustDecision(userConfigContents, candidates: candidates) {
            return []
        }

        // Codex canonicalizes its cwd before looking up `projects.<path>`.
        // macOS exposes `/tmp` as a symlink to `/private/tmp`, so targeting the
        // logical path would leave the trust prompt unresolved after restore.
        let overrideDirectory = canonicalProjectPath(currentDirectory)
        let escapedDirectory = tomlBasicStringContents(overrideDirectory)
        return [
            "-c",
            "projects={\"\(escapedDirectory)\"={trust_level=\"untrusted\"}}",
        ]
    }

    /// Resolves Codex's effective working root, including a global or
    /// resume-scoped `-C` / `--cd`. Relative values resolve from the process
    /// directory that Codex inherits, and the result uses Codex's canonical
    /// filesystem spelling.
    public func effectiveWorkingDirectory(
        arguments: [String],
        currentDirectory: String
    ) -> String? {
        guard let baseDirectory = normalizedAbsolutePath(currentDirectory) else {
            return nil
        }
        var selectedDirectory: String?
        var index = executableArgumentStart(arguments)
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                break
            }
            if argument == "-C" || argument == "--cd" {
                guard index + 1 < arguments.count else { return nil }
                selectedDirectory = arguments[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("-C=") {
                selectedDirectory = String(argument.dropFirst("-C=".count))
            } else if argument.hasPrefix("--cd=") {
                selectedDirectory = String(argument.dropFirst("--cd=".count))
            }
            index += 1
        }
        guard let selectedDirectory else {
            return canonicalProjectPath(baseDirectory)
        }
        let absoluteDirectory: String
        if selectedDirectory.hasPrefix("/") {
            absoluteDirectory = selectedDirectory
        } else {
            absoluteDirectory = (baseDirectory as NSString)
                .appendingPathComponent(selectedDirectory)
        }
        guard let normalized = normalizedAbsolutePath(absoluteDirectory) else {
            return nil
        }
        return canonicalProjectPath(normalized)
    }

    private func resumeSubcommandIndex(_ arguments: [String]) -> Int? {
        var index = executableArgumentStart(arguments)
        let valueOptions: Set<String> = [
            "-c", "--config",
            "--enable", "--disable",
            "-m", "--model",
            "-p", "--profile",
            "-C", "--cd",
            "--remote", "--remote-auth-token-env",
            "--local-provider",
            "-a", "--ask-for-approval",
            "-s", "--sandbox",
            "--add-dir",
        ]
        let flagOptions: Set<String> = [
            "--strict-config",
            "--oss",
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-bypass-hook-trust",
            "--search",
            "--no-alt-screen",
            "-h", "--help",
            "-V", "--version",
        ]
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                return nil
            }
            if argument == "resume" {
                return index
            }
            if valueOptions.contains(argument) {
                guard index + 1 < arguments.count else { return nil }
                index += 2
                continue
            }
            if flagOptions.contains(argument) || recognizedInlineOption(argument) {
                index += 1
                continue
            }
            // `--image` consumes one or more following values, so a later
            // positional `resume` cannot be identified as a subcommand.
            if argument == "-i" || argument == "--image" {
                return nil
            }
            // Unknown options fail closed. Treating a future option as a flag
            // could mistake its value `resume` for the subcommand and inject a
            // trust decision into a fresh launch.
            return nil
        }
        return nil
    }

    private func executableArgumentStart(_ arguments: [String]) -> Int {
        guard let first = arguments.first else { return 0 }
        return first == "codex"
            || (first.hasPrefix("/") && (first as NSString).lastPathComponent == "codex")
            ? 1
            : 0
    }

    private func recognizedInlineOption(_ argument: String) -> Bool {
        [
            "-c=", "--config=",
            "--enable=", "--disable=",
            "-i=", "--image=",
            "-m=", "--model=",
            "--remote=", "--remote-auth-token-env=",
            "--local-provider=",
            "-p=", "--profile=",
            "-s=", "--sandbox=",
            "-C=", "--cd=",
            "--add-dir=",
            "-a=", "--ask-for-approval=",
        ].contains { argument.hasPrefix($0) }
    }

    private func argumentsContainProjectTrustDecision(
        _ arguments: [String],
        candidates: Set<String>
    ) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if (argument == "-c" || argument == "--config"), index + 1 < arguments.count {
                if projectTrustOverrideMatches(arguments[index + 1], candidates: candidates) {
                    return true
                }
                index += 2
                continue
            }
            if argument.hasPrefix("-c="),
               projectTrustOverrideMatches(
                   String(argument.dropFirst("-c=".count)),
                   candidates: candidates
               ) {
                return true
            }
            if argument.hasPrefix("--config="),
               projectTrustOverrideMatches(
                   String(argument.dropFirst("--config=".count)),
                   candidates: candidates
               ) {
                return true
            }
            index += 1
        }
        return false
    }

    private func projectTrustOverrideMatches(
        _ override: String,
        candidates: Set<String>
    ) -> Bool {
        guard let equals = unquotedIndex(of: "=", in: override) else { return false }
        let key = override[..<equals].trimmingCharacters(in: .whitespaces)
        let value = override[override.index(after: equals)...]
            .trimmingCharacters(in: .whitespaces)
        if key == "projects" {
            return candidates.contains { inlineProjectDecision(override, path: $0) }
        }
        guard isCLITrustLevelValue(value),
              let path = projectPathFromEffectiveCLITrustKey(key) else {
            return false
        }
        return candidates.contains(normalizedAbsolutePath(path) ?? path)
    }

    /// Codex CLI overrides split key paths on literal dots without parsing
    /// quoted TOML key segments. Only an unquoted path without dots is an
    /// effective dotted `projects.<path>.trust_level` override.
    private func projectPathFromEffectiveCLITrustKey(_ key: String) -> String? {
        let prefix = "projects."
        let suffix = ".trust_level"
        guard key.hasPrefix(prefix),
              key.hasSuffix(suffix),
              key.count >= prefix.count + suffix.count else {
            return nil
        }
        let start = key.index(key.startIndex, offsetBy: prefix.count)
        let end = key.index(key.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        let path = String(key[start..<end])
        guard path.hasPrefix("/"),
              !path.contains(".") else {
            return nil
        }
        return path
    }

    private func userConfigContainsProjectTrustDecision(
        _ contents: String?,
        candidates: Set<String>
    ) -> Bool {
        guard let contents else { return false }
        var activeProjectPath: String?

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = stripTomlComment(String(rawLine))
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") {
                activeProjectPath = projectPathFromTableHeader(line)
                continue
            }

            if let activeProjectPath,
               candidates.contains(normalizedAbsolutePath(activeProjectPath) ?? activeProjectPath),
               let (key, value) = assignmentParts(line),
               key == "trust_level",
               isTrustLevelValue(value) {
                return true
            }

            if let (key, value) = assignmentParts(line),
               isTrustLevelValue(value),
               let path = projectPathFromDottedTrustKey(key),
               candidates.contains(normalizedAbsolutePath(path) ?? path) {
                return true
            }

            // Codex rewrites project decisions as explicit tables. Supporting
            // the common one-line inline form keeps manually authored config
            // from being needlessly downgraded; an ambiguous parse fails closed
            // and returns an untrusted invocation override.
            for candidate in candidates where inlineProjectDecision(line, path: candidate) {
                return true
            }
        }
        return false
    }

    private func projectPathFromTableHeader(_ line: String) -> String? {
        guard line.hasPrefix("["),
              line.hasSuffix("]"),
              !line.hasPrefix("[[") else {
            return nil
        }
        let body = line.dropFirst().dropLast()
            .trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("projects.") else { return nil }
        return parseTomlQuotedString(
            String(body.dropFirst("projects.".count))
                .trimmingCharacters(in: .whitespaces)
        )
    }

    private func projectPathFromDottedTrustKey(_ key: String) -> String? {
        guard key.hasPrefix("projects.") else { return nil }
        let remainder = String(key.dropFirst("projects.".count))
        guard let quoted = leadingTomlQuotedString(remainder) else { return nil }
        let suffix = remainder[quoted.endIndex...]
            .trimmingCharacters(in: .whitespaces)
        guard suffix == ".trust_level" else { return nil }
        return quoted.value
    }

    private func leadingTomlQuotedString(
        _ value: String
    ) -> (value: String, endIndex: String.Index)? {
        guard let quote = value.first, quote == "\"" || quote == "'" else {
            return nil
        }
        var result = ""
        var index = value.index(after: value.startIndex)
        var escaping = false
        while index < value.endIndex {
            let character = value[index]
            if quote == "\"", escaping {
                switch character {
                case "b": result.append("\u{08}")
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "f": result.append("\u{0c}")
                case "r": result.append("\r")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                default: return nil
                }
                escaping = false
            } else if quote == "\"", character == "\\" {
                escaping = true
            } else if character == quote {
                return (result, value.index(after: index))
            } else {
                result.append(character)
            }
            index = value.index(after: index)
        }
        return nil
    }

    private func parseTomlQuotedString(_ value: String) -> String? {
        guard let parsed = leadingTomlQuotedString(value),
              parsed.endIndex == value.endIndex else {
            return nil
        }
        return parsed.value
    }

    private func assignmentParts(_ line: String) -> (key: String, value: String)? {
        guard let equals = unquotedIndex(of: "=", in: line) else { return nil }
        return (
            line[..<equals].trimmingCharacters(in: .whitespaces),
            line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        )
    }

    private func unquotedIndex(of needle: Character, in value: String) -> String.Index? {
        var quote: Character?
        var escaping = false
        for index in value.indices {
            let character = value[index]
            if let activeQuote = quote {
                if activeQuote == "\"", escaping {
                    escaping = false
                } else if activeQuote == "\"", character == "\\" {
                    escaping = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == needle {
                return index
            }
        }
        return nil
    }

    private func stripTomlComment(_ line: String) -> String {
        guard let comment = unquotedIndex(of: "#", in: line) else { return line }
        return String(line[..<comment])
    }

    private func isTrustLevelValue(_ rawValue: String) -> Bool {
        guard let value = parseTomlQuotedString(rawValue) else { return false }
        return value == "trusted" || value == "untrusted"
    }

    private func isCLITrustLevelValue(_ rawValue: String) -> Bool {
        if isTrustLevelValue(rawValue) {
            return true
        }
        // Codex treats a config override value as a raw string literal when
        // TOML parsing fails, so unquoted trusted/untrusted are effective CLI
        // decisions even though the persisted config requires quoted strings.
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        return value == "trusted" || value == "untrusted"
    }

    private func inlineProjectDecision(_ line: String, path: String) -> Bool {
        let basicPath = "\"\(tomlBasicStringContents(path))\""
        let literalPath = path.contains("'") ? nil : "'\(path)'"
        guard line.contains(basicPath) || literalPath.map(line.contains) == true else {
            return false
        }
        guard line.contains("trust_level") else { return false }
        return line.contains("\"trusted\"")
            || line.contains("\"untrusted\"")
            || line.contains("'trusted'")
            || line.contains("'untrusted'")
    }

    private func normalizedAbsolutePath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/") else {
            return nil
        }
        return (path as NSString).standardizingPath
    }

    private func canonicalProjectPath(_ path: String) -> String {
        path.withCString { pointer -> String in
            guard let resolved = Darwin.realpath(pointer, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    private func tomlBasicStringContents(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0a: result += "\\n"
            case 0x0c: result += "\\f"
            case 0x0d: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0x00...0x1f, 0x7f:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
