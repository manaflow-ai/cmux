import Foundation

/// Recognizes the command OMX (oh-my-codex) starts its HUD pane with.
///
/// OMX opens the HUD through `tmux split-window` with a shell command such as
/// `exec env OMX_SESSION_ID=s1 node '/opt/oh-my-codex/dist/cli/omx.js' hud --watch`.
/// cmux launches that pane differently from a teammate split and runs its
/// saved command again on session restore, so the match is on the invocation
/// itself: text that only mentions `omx` and `hud`, like `echo omx hud`, is
/// not a HUD, and neither is a HUD invocation with anything else for the
/// shell to run attached to it.
///
/// ```swift
/// let matcher = OMXHudCommandMatcher()
/// matcher.matches(command: "node '/opt/oh-my-codex/dist/omx.js' hud --watch")  // true
/// matcher.matches(command: "echo omx hud")                                     // false
/// matcher.matches(command: "omx hud --watch; rm -rf build")                    // false
/// ```
public struct OMXHudCommandMatcher: Sendable {
    private let executableNames: Set<String> = ["omx", "oh-my-codex"]
    private let packageDirectoryName = "oh-my-codex"
    private let javaScriptRuntimeNames: Set<String> = ["node", "nodejs", "bun"]
    private let scriptExtensions = [".js", ".mjs", ".cjs"]
    /// Unquoted characters that make a shell run, chain or redirect something.
    private let shellOperatorCharacters: Set<Character> = [";", "&", "|", "<", ">", "(", ")", "$", "`", "#"]

    /// Creates a matcher for the HUD invocations OMX is known to produce.
    public init() {}

    /// Whether `command` is one simple shell command that runs `hud --watch` through an OMX entry point.
    ///
    /// Accepts the `omx` or `oh-my-codex` executable, or `node`, `nodejs` or
    /// `bun` running an OMX entry script (`omx.js`, or any script inside an
    /// `oh-my-codex` package directory), after any leading `exec`, `env` and
    /// variable assignments. The text is rejected outright if it holds a
    /// second line, a command separator, a redirection or a substitution
    /// outside single quotes, since the caller hands the whole text to a shell.
    ///
    /// - Parameter command: The pane command as a shell would receive it.
    /// - Parameter launchedThroughOMXShim: Whether the caller is known to be
    ///   OMX, as when the split arrives through its cmux shim. A development
    ///   checkout runs an entry script that is not named after OMX, so then
    ///   any script a JavaScript runtime runs is accepted. Defaults to `false`
    ///   because a saved command carries no such evidence.
    /// - Returns: `true` only for an OMX `hud --watch` invocation.
    public func matches(command: String, launchedThroughOMXShim: Bool = false) -> Bool {
        guard let words = simpleCommandWords(command) else { return false }
        return matches(words: words, launchedThroughOMXShim: launchedThroughOMXShim)
    }

    /// Whether the words of one simple command run `hud --watch` through an OMX entry point.
    func matches(words: [String], launchedThroughOMXShim: Bool = false) -> Bool {
        let command = words.drop { $0 == "exec" || $0 == "env" || isVariableAssignment($0) }
        guard let executable = command.first else { return false }

        let arguments: ArraySlice<String>
        if javaScriptRuntimeNames.contains(lastPathComponent(executable)) {
            guard let script = command.dropFirst().first,
                  !script.hasPrefix("-"),
                  launchedThroughOMXShim || isOMXEntryScript(script) else {
                return false
            }
            arguments = command.dropFirst(2)
        } else if executableNames.contains(lastPathComponent(executable)) {
            arguments = command.dropFirst()
        } else {
            return false
        }

        return arguments.first == "hud" && arguments.dropFirst().contains("--watch")
    }

    /// Splits `command` into words, or returns `nil` when it is more than one simple command.
    ///
    /// Single quotes are literal. Inside double quotes a `$` or backtick still
    /// substitutes, so those are refused there as well as unquoted.
    private func simpleCommandWords(_ command: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var escaping = false

        for character in command {
            if character.isNewline { return nil }
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            switch quote {
            case "'":
                if character == "'" { quote = nil } else { current.append(character) }
            case "\"":
                if character == "\"" {
                    quote = nil
                } else if character == "\\" {
                    escaping = true
                } else if character == "$" || character == "`" {
                    return nil
                } else {
                    current.append(character)
                }
            default:
                if character == "'" || character == "\"" {
                    quote = character
                    hasCurrent = true
                } else if character == "\\" {
                    escaping = true
                    hasCurrent = true
                } else if character == " " || character == "\t" {
                    if hasCurrent { words.append(current) }
                    current = ""
                    hasCurrent = false
                } else if shellOperatorCharacters.contains(character) {
                    return nil
                } else {
                    current.append(character)
                    hasCurrent = true
                }
            }
        }

        guard quote == nil, !escaping else { return nil }
        if hasCurrent { words.append(current) }
        return words
    }

    /// Whether `path` is OMX's entry script, by name or by living in its package directory.
    private func isOMXEntryScript(_ path: String) -> Bool {
        var name = lastPathComponent(path)
        if let scriptExtension = scriptExtensions.first(where: name.hasSuffix) {
            name = String(name.dropLast(scriptExtension.count))
        }
        if executableNames.contains(name) { return true }
        return path.lowercased().split(separator: "/").dropLast().contains(Substring(packageDirectoryName))
    }

    private func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent.lowercased()
    }

    private func isVariableAssignment(_ word: String) -> Bool {
        guard let equalsIndex = word.firstIndex(of: "="), equalsIndex > word.startIndex else {
            return false
        }
        return word[..<equalsIndex].unicodeScalars.enumerated().allSatisfy { offset, scalar in
            guard scalar.isASCII else { return false }
            return scalar == "_" || scalar.properties.isAlphabetic
                || (offset > 0 && scalar.properties.numericType != nil)
        }
    }
}
