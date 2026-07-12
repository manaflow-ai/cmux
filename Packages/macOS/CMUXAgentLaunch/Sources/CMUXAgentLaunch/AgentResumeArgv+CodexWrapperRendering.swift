import Foundation

extension AgentResumeArgv {
    /// Wraps a rendered codex resume command so it parses in any login shell.
    ///
    /// Mirror of ``portableClaudeResumeShellCommand(posixCommand:)`` for codex:
    /// ``codexWrapperShellExecutableToken`` is POSIX-only command substitution,
    /// but the rendered codex resume command is dispatched through the user's
    /// `$SHELL` by the restore launcher and copy-pasted into the user's
    /// interactive shell (fish/csh included), so wrapping it in
    /// `/bin/sh -c '<command>'` makes every dispatching shell parse it
    /// identically while `sh` still inherits `CMUX_CODEX_WRAPPER_SHIM` from the
    /// managed terminal environment (and falls back to bare `codex` when unset).
    public static func portableCodexResumeShellCommand(posixCommand: String) -> String {
        "/bin/sh -c " + posixSingleQuoted(posixCommand)
    }

    /// Renders a codex resume/fork command through
    /// ``renderingCodexWrapperExecutable(parts:quote:)`` and joins it, wrapping via
    /// ``portableCodexResumeShellCommand(posixCommand:)`` only when the wrapper token was
    /// actually substituted.
    ///
    /// The `/bin/sh -c` layer exists solely to make the POSIX-only token parse in
    /// non-POSIX shells, so it is applied exactly when the token is present. Direct
    /// resume/fork commands with captured executable paths are routed through the wrapper
    /// with `CMUX_CUSTOM_CODEX_PATH` so hook injection and executable identity both survive.
    public static func renderedPortableCodexResumeShellCommand(
        parts: [String],
        quote: (String) -> String
    ) -> String {
        let rendered = renderingCodexWrapperExecutable(parts: parts, quote: quote)
        let joined = rendered.joined(separator: " ")
        guard rendered.contains(codexWrapperShellExecutableToken) else { return joined }
        return portableCodexResumeShellCommand(posixCommand: joined)
    }

    /// Renders shell command `parts` to quoted tokens, routing a direct codex resume/fork
    /// command through ``codexWrapperShellExecutableToken``.
    ///
    /// A bare `codex` executable is replaced directly. A captured absolute/custom executable
    /// is preserved as `CMUX_CUSTOM_CODEX_PATH` while the command itself re-enters the wrapper;
    /// this prevents a resumed session's generated fork from bypassing hook injection. Existing
    /// `env` options and assignments are retained, and cmux launchers such as `codex-teams` stay
    /// unchanged. Call only for the codex kind.
    /// https://github.com/manaflow-ai/cmux/issues/5639
    public static func renderingCodexWrapperExecutable(
        parts: [String],
        quote: (String) -> String
    ) -> [String] {
        guard let command = directCodexCommand(in: parts),
              command.executableIndex + 1 < parts.count,
              parts[command.executableIndex + 1] == "resume" ||
                parts[command.executableIndex + 1] == "fork" else {
            return parts.map(quote)
        }

        let executable = parts[command.executableIndex]
        if executable == "codex", command.usesUtilityPath {
            // `env -P` selects the real Codex from a utility path. Replacing that
            // command with the absolute cmux wrapper would silently select a different
            // Codex, so leave this uncommon ambiguous form unchanged.
            return parts.map(quote)
        }
        let usesCustomExecutable = executable != "codex"
        var rendered: [String] = []
        if let environmentCommandIndex = command.environmentCommandIndex {
            if !command.leadingAssignments.isEmpty {
                // Preserve `KEY=value env -i ...` semantics. Quoted assignment words are
                // not shell assignment syntax, so an outer `env` carries them to the
                // captured env command, whose own flags still apply afterward.
                rendered.append(quote("env"))
                rendered.append(contentsOf: command.leadingAssignments.map { quote(parts[$0]) })
            }
            rendered.append(quote(parts[environmentCommandIndex]))
            rendered.append(contentsOf: command.environmentOptions.map { quote(parts[$0]) })
        } else if usesCustomExecutable || !command.leadingAssignments.isEmpty {
            rendered.append(quote("env"))
            rendered.append(contentsOf: command.leadingAssignments.map { quote(parts[$0]) })
        }
        rendered.append(contentsOf: command.environmentAssignments.map { quote(parts[$0]) })
        if command.clearsInheritedEnvironment {
            // `/bin/sh` expands these fixed-name assignments before `env -i` runs,
            // retaining only the cmux control channel the wrapper needs to inject hooks.
            let explicitlyConfiguredKeys = Set(command.environmentAssignments.compactMap {
                environmentAssignmentName(parts[$0])
            }).union(environmentUnsetNames(in: parts, options: command.environmentOptions))
            rendered.append(contentsOf: codexWrapperInheritedEnvironmentAssignments.filter {
                !explicitlyConfiguredKeys.contains($0.key)
            }.map { $0.assignment })
        }
        if usesCustomExecutable {
            rendered.append(quote("CMUX_CUSTOM_CODEX_PATH=\(executable)"))
        }
        rendered.append(codexWrapperShellExecutableToken)
        rendered.append(contentsOf: parts[(command.executableIndex + 1)...].map(quote))
        return rendered
    }

    private struct DirectCodexCommand {
        var executableIndex: Int
        var environmentCommandIndex: Int?
        var leadingAssignments: Range<Int>
        var environmentOptions: Range<Int>
        var environmentAssignments: Range<Int>
        var clearsInheritedEnvironment: Bool
        var usesUtilityPath: Bool
    }

    private static func directCodexCommand(in parts: [String]) -> DirectCodexCommand? {
        guard !parts.isEmpty else { return nil }

        var index = 0
        while index < parts.count, isEnvironmentAssignment(parts[index]) {
            index += 1
        }
        let leadingAssignments = 0..<index

        var environmentCommandIndex: Int?
        var environmentOptions = index..<index
        if index < parts.count, isEnvironmentCommand(parts[index]) {
            environmentCommandIndex = index
            index += 1
            let optionsStart = index
            guard let commandStart = indexAfterEnvironmentOptions(in: parts, from: index) else {
                return nil
            }
            index = commandStart
            environmentOptions = optionsStart..<index
        }

        let assignmentsStart = index
        while index < parts.count, isEnvironmentAssignment(parts[index]) {
            index += 1
        }
        guard index < parts.count else { return nil }
        return DirectCodexCommand(
            executableIndex: index,
            environmentCommandIndex: environmentCommandIndex,
            leadingAssignments: leadingAssignments,
            environmentOptions: environmentOptions,
            environmentAssignments: assignmentsStart..<index,
            clearsInheritedEnvironment: environmentOptions.contains {
                parts[$0] == "-"
                    || parts[$0] == "--ignore-environment"
                    || parsedEnvironmentShortOption(parts[$0])?.clearsInheritedEnvironment == true
            },
            usesUtilityPath: environmentOptions.contains {
                parsedEnvironmentShortOption(parts[$0])?.usesUtilityPath == true
            }
        )
    }

    private static let codexWrapperInheritedEnvironmentAssignments = [
        "PATH",
        "CMUX_BUNDLED_CLI_PATH",
        "CMUX_CODEX_HOOKS_DISABLED",
        "CMUX_CODEX_WRAPPER_SHIM",
        "CMUX_CODEX_WRAPPER_SHIM_ROOT",
        "CMUX_SOCKET_PATH",
        "CMUX_SURFACE_ID",
        "CMUX_WORKSPACE_ID",
    ].map { key in
        (key: key, assignment: key + "=\"${" + key + ":-}\"")
    }

    private static func indexAfterEnvironmentOptions(in parts: [String], from start: Int) -> Int? {
        var index = start
        while index < parts.count {
            let option = parts[index]
            if option == "--" {
                return index + 1
            }
            if option == "-" {
                index += 1
                continue
            }
            if option == "--ignore-environment" || option == "--null" ||
                option == "--debug" ||
                option == "--list-signal-handling" ||
                option == "--block-signal" || option.hasPrefix("--block-signal=") ||
                option == "--default-signal" || option.hasPrefix("--default-signal=") ||
                option == "--ignore-signal" || option.hasPrefix("--ignore-signal=") ||
                option.hasPrefix("--unset=") || option.hasPrefix("--chdir=") {
                index += 1
                continue
            }
            if option == "--unset" || option == "--chdir" {
                guard index + 1 < parts.count else { return nil }
                index += 2
                continue
            }
            if option == "--split-string" || option.hasPrefix("--split-string=") {
                // The command is embedded in the split string, so its executable cannot be
                // identified without reimplementing `env`'s parser.
                return nil
            }
            if option.hasPrefix("-"), !option.hasPrefix("--") {
                guard let parsed = parsedEnvironmentShortOption(option),
                      index + parsed.width <= parts.count else {
                    return nil
                }
                index += parsed.width
                continue
            }
            if option.hasPrefix("-") {
                return nil
            }
            return index
        }
        return index
    }

    private static func environmentUnsetNames(
        in parts: [String],
        options: Range<Int>
    ) -> Set<String> {
        var names = Set<String>()
        var index = options.lowerBound
        while index < options.upperBound {
            let option = parts[index]
            if option == "--unset" {
                if index + 1 < options.upperBound {
                    names.insert(parts[index + 1])
                }
                index += 2
                continue
            }
            if option.hasPrefix("--unset=") {
                names.insert(String(option.dropFirst("--unset=".count)))
                index += 1
                continue
            }
            if option == "--chdir" {
                index += 2
                continue
            }
            guard option.hasPrefix("-"), !option.hasPrefix("--") else {
                index += 1
                continue
            }

            let characters = Array(option.dropFirst())
            var characterIndex = 0
            var consumedOperand = false
            while characterIndex < characters.count {
                switch characters[characterIndex] {
                case "0", "i", "v":
                    characterIndex += 1
                case "u":
                    let nameStart = characters.index(after: characterIndex)
                    if nameStart < characters.endIndex {
                        names.insert(String(characters[nameStart...]))
                    } else if index + 1 < options.upperBound {
                        names.insert(parts[index + 1])
                        consumedOperand = true
                    }
                    characterIndex = characters.endIndex
                case "C", "P", "S":
                    consumedOperand = characterIndex + 1 == characters.count
                    characterIndex = characters.endIndex
                default:
                    characterIndex = characters.endIndex
                }
            }
            index += consumedOperand ? 2 : 1
        }
        return names
    }

    private struct ParsedEnvironmentShortOption {
        let width: Int
        let clearsInheritedEnvironment: Bool
        let usesUtilityPath: Bool
    }

    /// Parses BSD/GNU `env` short-option clusters. `0`, `i`, and `v` are flags;
    /// `u`, `C`, and `P` consume the remaining cluster or the next word. `S` is
    /// intentionally unsupported because it embeds the command in a split string.
    private static func parsedEnvironmentShortOption(_ option: String) -> ParsedEnvironmentShortOption? {
        guard option.hasPrefix("-"),
              !option.hasPrefix("--"),
              option.count > 1 else {
            return nil
        }
        let characters = Array(option.dropFirst())
        var clearsInheritedEnvironment = false
        var usesUtilityPath = false
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "0", "v":
                index += 1
            case "i":
                clearsInheritedEnvironment = true
                index += 1
            case "u", "C", "P":
                if characters[index] == "P" {
                    usesUtilityPath = true
                }
                return ParsedEnvironmentShortOption(
                    width: index + 1 < characters.count ? 1 : 2,
                    clearsInheritedEnvironment: clearsInheritedEnvironment,
                    usesUtilityPath: usesUtilityPath
                )
            case "S":
                return nil
            default:
                return nil
            }
        }
        return ParsedEnvironmentShortOption(
            width: 1,
            clearsInheritedEnvironment: clearsInheritedEnvironment,
            usesUtilityPath: usesUtilityPath
        )
    }

    private static func isEnvironmentCommand(_ value: String) -> Bool {
        value == "env" || value.hasSuffix("/env")
    }

    private static func isEnvironmentAssignment(_ value: String) -> Bool {
        guard let equalsIndex = value.firstIndex(of: "="), equalsIndex != value.startIndex else {
            return false
        }
        let name = value[..<equalsIndex]
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return name.unicodeScalars.dropFirst().allSatisfy { allowed.contains($0) }
    }

    private static func environmentAssignmentName(_ value: String) -> String? {
        guard isEnvironmentAssignment(value),
              let equalsIndex = value.firstIndex(of: "=") else {
            return nil
        }
        return String(value[..<equalsIndex])
    }
}
