import Foundation

/// Describes which captured cwd options an agent kind lets restore drop without
/// comparing their value to a saved directory.
///
/// Remote restores trust no captured cwd value, so they remove cwd options
/// outright. That is only safe for spellings whose cwd meaning is known for the
/// agent: Claude's `-w` is `--worktree`, Qoder's `--workspace` selects a saved
/// profile, and an unknown agent may use `-C` for anything. Those stay in the
/// argv and are only removed when their value matches a saved cwd.
public struct AgentWorkingDirectoryOptionPolicy: Sendable, Equatable {
    /// Options (split or `=` form) that may be removed regardless of their value.
    public let unconditionallyRemovableValueOptions: Set<String>
    /// Short options whose attached value (`-C/dir`) may be removed regardless of the value.
    public let unconditionallyRemovableAttachedShortOptions: Set<String>

    /// Creates the policy for a built-in agent kind.
    ///
    /// - Parameter agentKind: The exact cmux built-in kind, or `nil` for a custom
    ///   registration or an unknown agent.
    public init(agentKind: String?) {
        var valueOptions: Set<String> = ["--cd", "--cwd", "--work-dir"]
        var attachedShortOptions: Set<String> = []
        switch agentKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "codex":
            valueOptions.insert("-C")
            attachedShortOptions.insert("-C")
        case "kimi", "qoder":
            // Qoder's `--workspace` selects a saved workspace, not a cwd, so only `-w` is safe.
            valueOptions.insert("-w")
            attachedShortOptions.insert("-w")
        case "cursor":
            // Cursor's `--workspace` selects the cwd.
            valueOptions.insert("--workspace")
        default:
            break
        }
        unconditionallyRemovableValueOptions = valueOptions
        unconditionallyRemovableAttachedShortOptions = attachedShortOptions
    }
}
