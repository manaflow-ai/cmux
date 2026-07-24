import Darwin
import Foundation

/// Keeps unattended Codex resume non-interactive without granting project trust.
///
/// Codex prompts when the active working directory and its repository root have
/// no explicit project trust decision. A cmux auto-resume cannot answer that
/// prompt safely, so an undecided resume receives an invocation-only `untrusted`
/// override. The caller supplies project decisions from Codex's own effective
/// configuration, preserving system, enterprise, managed, user, profile,
/// project, and command-line layers.
public struct CodexResumeTrustPolicy: Sendable, Equatable {
    /// Creates a stateless Codex resume trust policy.
    public init() {}

    /// Returns the `-c key=value` pair needed to skip Codex's directory-trust
    /// prompt safely, or an empty array when this is not a resume or Codex can
    /// already resolve an explicit decision.
    public func undecidedProjectOverride(
        arguments: [String],
        currentDirectory: String,
        repositoryRoot: String?,
        effectiveProjectDecisionPaths: Set<String>
    ) -> [String] {
        guard isResumeInvocation(arguments: arguments) else { return [] }

        let currentDirectory = effectiveWorkingDirectory(
            arguments: arguments,
            currentDirectory: currentDirectory
        )
        guard let currentDirectory else { return [] }

        var candidates = Set<String>()
        for path in [currentDirectory, repositoryRoot].compactMap({ normalizedAbsolutePath($0) }) {
            candidates.insert(path)
            candidates.insert(canonicalProjectPath(path))
        }

        var decisions = Set<String>()
        for path in effectiveProjectDecisionPaths.compactMap({ normalizedAbsolutePath($0) }) {
            decisions.insert(path)
            decisions.insert(canonicalProjectPath(path))
        }
        guard candidates.isDisjoint(with: decisions) else { return [] }

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

    /// Whether the captured invocation contains a real `resume` subcommand.
    /// Unknown global options fail closed because their values could be named
    /// `resume`.
    public func isResumeInvocation(arguments: [String]) -> Bool {
        resumeSubcommandIndex(arguments) != nil
    }

    /// Root arguments for an authoritative `codex app-server config/read`.
    ///
    /// The app server loads every Codex configuration layer itself. Profile and
    /// `-c` options from both the global and resume scopes are replayed as root
    /// options so the returned `projects` map matches the resumed invocation.
    /// Prompt text after `--` is never interpreted as configuration.
    public func appServerConfigurationArguments(arguments: [String]) -> [String]? {
        guard let resumeIndex = resumeSubcommandIndex(arguments) else { return nil }

        var profile: String?
        var forwardedArguments: [String] = []
        var index = executableArgumentStart(arguments)
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                break
            }
            if index == resumeIndex {
                index += 1
                continue
            }
            // A remote TUI gets effective config from its remote app server.
            // Querying a new local app server would not describe that session.
            if argument == "--remote" || argument.hasPrefix("--remote=") {
                return nil
            }
            if argument == "-c" || argument == "--config" {
                guard index + 1 < arguments.count else { return nil }
                forwardedArguments.append(contentsOf: ["-c", arguments[index + 1]])
                index += 2
                continue
            }
            if let value = attachedShortOptionValue(argument, option: "c") {
                forwardedArguments.append(contentsOf: ["-c", value])
            } else if argument.hasPrefix("--config=") {
                let value = String(argument.dropFirst("--config=".count))
                forwardedArguments.append(contentsOf: ["-c", value])
            } else if argument == "-p" || argument == "--profile" {
                guard index + 1 < arguments.count,
                      let value = normalizedProfileName(arguments[index + 1]) else {
                    return nil
                }
                profile = value
                index += 2
                continue
            } else if let rawValue = attachedShortOptionValue(
                argument,
                option: "p"
            ) {
                guard let value = normalizedProfileName(rawValue) else {
                    return nil
                }
                profile = value
            } else if argument.hasPrefix("--profile=") {
                guard let value = normalizedProfileName(
                    String(argument.dropFirst("--profile=".count))
                ) else {
                    return nil
                }
                profile = value
            } else if argument == "--strict-config" {
                forwardedArguments.append(argument)
            } else if argument == "-i" || argument == "--image" {
                // Image accepts a variable number of values. Do not risk
                // mistaking a later image path for a configuration option.
                return nil
            } else if appServerIgnoredValueOptions.contains(argument) {
                guard index + 1 < arguments.count else { return nil }
                index += 2
                continue
            } else if appServerIgnoredFlags.contains(argument)
                || recognizedInlineOption(argument)
            {
                // These options cannot alter project trust.
            } else if argument.hasPrefix("-") {
                // Unknown future options may consume a following value.
                return nil
            }
            index += 1
        }

        var result: [String] = []
        if let profile {
            result.append(contentsOf: ["--profile", profile])
        }
        result.append(contentsOf: forwardedArguments)
        return result
    }

    /// Extracts decided project paths from a `config/read` JSONL response.
    ///
    /// Missing `projects` is a valid empty configuration. Malformed output,
    /// an RPC error, or an unexpected `projects` shape returns nil so the caller
    /// can fail closed and leave Codex's trust picker intact.
    public func effectiveProjectDecisionPaths(
        appServerOutput: String,
        responseID: Int = 2
    ) -> Set<String>? {
        for line in appServerOutput.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == responseID else {
                continue
            }
            guard object["error"] == nil,
                  let result = object["result"] as? [String: Any],
                  let config = result["config"] as? [String: Any] else {
                return nil
            }
            guard let rawProjects = config["projects"] else {
                return []
            }
            if rawProjects is NSNull {
                return []
            }
            guard let projects = rawProjects as? [String: Any] else {
                return nil
            }

            var decisions = Set<String>()
            for (path, rawProject) in projects {
                guard let project = rawProject as? [String: Any] else {
                    return nil
                }
                guard let rawTrustLevel = project["trust_level"] else {
                    continue
                }
                guard let trustLevel = rawTrustLevel as? String,
                      trustLevel == "trusted" || trustLevel == "untrusted" else {
                    return nil
                }
                guard let normalized = normalizedAbsolutePath(path) else {
                    continue
                }
                decisions.insert(normalized)
                decisions.insert(canonicalProjectPath(normalized))
            }
            return decisions
        }
        return nil
    }

    /// Resolves Codex's effective working root, including a global or
    /// resume-scoped `-C` / `--cd`. Relative values resolve from the process
    /// directory that Codex inherits. The result preserves the normalized
    /// logical spelling because Codex checks it as well as the canonical path.
    public func effectiveWorkingDirectory(
        arguments: [String],
        currentDirectory: String
    ) -> String? {
        guard isResumeInvocation(arguments: arguments),
              let baseDirectory = normalizedAbsolutePath(currentDirectory) else {
            return nil
        }
        let valueOptions: Set<String> = [
            "-c", "--config",
            "--enable", "--disable",
            "-m", "--model",
            "--remote", "--remote-auth-token-env",
            "--local-provider",
            "-p", "--profile",
            "-s", "--sandbox",
            "--add-dir",
            "-a", "--ask-for-approval",
        ]
        let flagOptions: Set<String> = [
            "--strict-config",
            "--oss",
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-bypass-hook-trust",
            "--yolo",
            "--search",
            "--no-alt-screen",
            "--last",
            "--all",
            "--include-non-interactive",
            "-h", "--help",
            "-V", "--version",
        ]
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
            if let value = attachedShortOptionValue(argument, option: "C") {
                selectedDirectory = value
            } else if argument.hasPrefix("--cd=") {
                selectedDirectory = String(argument.dropFirst("--cd=".count))
            } else if argument == "-i" || argument == "--image" {
                return nil
            } else if valueOptions.contains(argument) {
                guard index + 1 < arguments.count else { return nil }
                index += 2
                continue
            } else if flagOptions.contains(argument)
                || recognizedInlineOption(argument)
            {
                // These options cannot select the working directory.
            } else if argument.hasPrefix("-") {
                return nil
            }
            index += 1
        }
        guard let selectedDirectory else {
            return baseDirectory
        }
        let absoluteDirectory: String
        if selectedDirectory.hasPrefix("/") {
            absoluteDirectory = selectedDirectory
        } else {
            absoluteDirectory = (baseDirectory as NSString)
                .appendingPathComponent(selectedDirectory)
        }
        return normalizedAbsolutePath(absoluteDirectory)
    }

    /// Returns the profile selected for the resumed invocation. Codex accepts
    /// the option in either the global or resume argument scope and uses the
    /// last occurrence.
    public func selectedProfile(arguments: [String]) -> String? {
        guard isResumeInvocation(arguments: arguments) else { return nil }
        let valueOptions: Set<String> = [
            "-c", "--config",
            "--enable", "--disable",
            "-m", "--model",
            "--remote", "--remote-auth-token-env",
            "--local-provider",
            "-s", "--sandbox",
            "-C", "--cd",
            "--add-dir",
            "-a", "--ask-for-approval",
        ]
        var selectedProfile: String?
        var index = executableArgumentStart(arguments)
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                break
            }
            if argument == "-p" || argument == "--profile" {
                guard index + 1 < arguments.count else { return nil }
                selectedProfile = normalizedProfileName(arguments[index + 1])
                index += 2
                continue
            }
            if argument == "-i" || argument == "--image" {
                return nil
            }
            if valueOptions.contains(argument) {
                guard index + 1 < arguments.count else { return nil }
                index += 2
                continue
            }
            if let value = attachedShortOptionValue(argument, option: "p") {
                selectedProfile = normalizedProfileName(value)
            } else if argument.hasPrefix("--profile=") {
                selectedProfile = normalizedProfileName(
                    String(argument.dropFirst("--profile=".count))
                )
            }
            index += 1
        }
        return selectedProfile
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
            "--yolo",
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
            // Image options consume one or more values. Even an attached first
            // value may be followed by another value named `resume`.
            if argument == "-i"
                || argument == "--image"
                || attachedShortOptionValue(argument, option: "i") != nil
                || argument.hasPrefix("--image=")
            {
                return nil
            }
            if flagOptions.contains(argument) || recognizedInlineOption(argument) {
                index += 1
                continue
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
        recognizedAttachedShortOption(argument) || [
            "--config=",
            "--enable=", "--disable=",
            "--image=",
            "--model=",
            "--remote=", "--remote-auth-token-env=",
            "--local-provider=",
            "--profile=",
            "--sandbox=",
            "--cd=",
            "--add-dir=",
            "--ask-for-approval=",
        ].contains { argument.hasPrefix($0) }
    }

    private func recognizedAttachedShortOption(_ argument: String) -> Bool {
        ["c", "i", "m", "p", "s", "C", "a"].contains {
            attachedShortOptionValue(argument, option: $0) != nil
        }
    }

    private func attachedShortOptionValue(
        _ argument: String,
        option: Character
    ) -> String? {
        guard argument.first == "-", !argument.hasPrefix("--") else {
            return nil
        }
        let optionIndex = argument.index(after: argument.startIndex)
        guard optionIndex < argument.endIndex,
              argument[optionIndex] == option else {
            return nil
        }
        var valueIndex = argument.index(after: optionIndex)
        guard valueIndex < argument.endIndex else { return nil }
        if argument[valueIndex] == "=" {
            valueIndex = argument.index(after: valueIndex)
        }
        guard valueIndex < argument.endIndex else { return nil }
        return String(argument[valueIndex...])
    }

    private var appServerIgnoredValueOptions: Set<String> {
        [
            "--enable", "--disable",
            "-m", "--model",
            "--remote-auth-token-env",
            "--local-provider",
            "-s", "--sandbox",
            "-C", "--cd",
            "--add-dir",
            "-a", "--ask-for-approval",
        ]
    }

    private var appServerIgnoredFlags: Set<String> {
        [
            "--oss",
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-bypass-hook-trust",
            "--yolo",
            "--search",
            "--no-alt-screen",
            "--last",
            "--all",
            "--include-non-interactive",
        ]
    }

    private func normalizedAbsolutePath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/") else {
            return nil
        }
        return (path as NSString).standardizingPath
    }

    private func normalizedProfileName(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
