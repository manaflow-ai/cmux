import Foundation

/// Recognizes the command OMX (oh-my-codex) starts its HUD pane with.
///
/// OMX opens the HUD through `tmux split-window` with a shell command such as
/// `exec env OMX_SESSION_ID=s1 node '/opt/oh-my-codex/dist/cli/omx.js' hud --watch`.
/// cmux launches that pane differently from a teammate split and relaunches it
/// on session restore, so the match is on the invocation itself: text that
/// only mentions `omx` and `hud`, like `echo omx hud`, is not a HUD.
///
/// ```swift
/// let matcher = OMXHudCommandMatcher()
/// matcher.matches(["omx", "hud", "--watch"])  // true
/// matcher.matches(["echo", "omx", "hud"])     // false
/// ```
public struct OMXHudCommandMatcher: Sendable {
    private let entryNames: Set<String> = ["omx", "oh-my-codex"]
    private let javaScriptRuntimeNames: Set<String> = ["node", "nodejs", "bun"]
    private let scriptExtensions = [".js", ".mjs", ".cjs"]
    private let plainArgumentCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=.,:/@%+"
    )

    /// Creates a matcher for the HUD invocations OMX is known to produce.
    public init() {}

    /// Whether `words` run `hud --watch` through an OMX entry point.
    ///
    /// Accepts the `omx` or `oh-my-codex` executable, or a JavaScript runtime
    /// running an OMX entry script, after any leading `exec`, `env` and
    /// variable assignments. Everything after `hud` must be a plain argument,
    /// so a command that chains something else onto the HUD does not match.
    ///
    /// - Parameter words: The command split into shell words, quotes removed.
    /// - Parameter launchedThroughOMXShim: Whether the caller is known to be
    ///   OMX, as when the split arrives through its cmux shim. A development
    ///   checkout runs an entry script that is not named after OMX, so then
    ///   any script a JavaScript runtime runs is accepted. Defaults to `false`
    ///   because a saved command carries no such evidence.
    /// - Returns: `true` only for an OMX `hud --watch` invocation.
    public func matches(_ words: [String], launchedThroughOMXShim: Bool = false) -> Bool {
        let command = words.drop { $0 == "exec" || $0 == "env" || isVariableAssignment($0) }
        guard let executable = command.first else { return false }

        let arguments: ArraySlice<String>
        if isOMXEntry(executable) {
            arguments = command.dropFirst()
        } else if javaScriptRuntimeNames.contains(lastPathComponent(executable)),
                  let script = command.dropFirst().first,
                  !script.hasPrefix("-"),
                  launchedThroughOMXShim || isOMXEntry(script) {
            arguments = command.dropFirst(2)
        } else {
            return false
        }

        guard arguments.first == "hud" else { return false }
        let hudArguments = arguments.dropFirst()
        return hudArguments.contains("--watch") && hudArguments.allSatisfy(isPlainArgument)
    }

    /// Whether `path` names the OMX executable or a script inside its package.
    private func isOMXEntry(_ path: String) -> Bool {
        var name = lastPathComponent(path)
        for scriptExtension in scriptExtensions where name.hasSuffix(scriptExtension) {
            name = String(name.dropLast(scriptExtension.count))
            break
        }
        if entryNames.contains(name) { return true }
        return path.lowercased().split(separator: "/").dropLast().contains("oh-my-codex")
    }

    private func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent.lowercased()
    }

    private func isVariableAssignment(_ word: String) -> Bool {
        guard let equalsIndex = word.firstIndex(of: "="), equalsIndex > word.startIndex else {
            return false
        }
        return word[..<equalsIndex].unicodeScalars.enumerated().allSatisfy { offset, scalar in
            scalar == "_" || (scalar.isASCII && scalar.properties.isAlphabetic)
                || (offset > 0 && scalar.isASCII && scalar.properties.numericType != nil)
        }
    }

    /// Whether `word` is free of the operators a shell would act on.
    private func isPlainArgument(_ word: String) -> Bool {
        !word.isEmpty && word.unicodeScalars.allSatisfy(plainArgumentCharacters.contains)
    }
}
