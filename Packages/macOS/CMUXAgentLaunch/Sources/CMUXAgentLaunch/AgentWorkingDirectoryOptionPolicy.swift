import Foundation

/// Describes agent argv options that carry a working-directory value.
public struct AgentWorkingDirectoryOptionPolicy: Sendable {
    /// Options whose cwd value is stored in the following token or after `=`.
    public let valueOptions: Set<String>
    /// Options that are unambiguously cwd-bearing and may be removed without
    /// comparing their value to a captured directory.
    public let unconditionallyRemovableValueOptions: Set<String>
    /// Short options whose cwd value may be attached to the option token.
    public let attachedShortValueOptions: Set<String>

    /// Creates the option policy for an agent kind.
    ///
    /// Ambiguous short options are enabled only for agents where their cwd meaning is known.
    /// An unknown kind retains legacy split `-C <cwd>` matching, but does not interpret an
    /// arbitrary token beginning with `-C` as an attached cwd value.
    ///
    /// - Parameter agentKind: The agent kind, when known.
    public init(agentKind: String? = nil) {
        self.init(agentKind: agentKind, builtInAgentKind: agentKind)
    }

    /// Creates an option policy with an explicit built-in identity.
    ///
    /// `agentKind` describes the captured command and may be a user-defined
    /// Vault id that happens to reuse a built-in spelling. `builtInAgentKind`
    /// is therefore the only value allowed to enable provider-specific
    /// cwd flags that are safe to remove without comparing their value. Pass
    /// `nil` for a custom registration so profile/workspace flags such as
    /// Kimi's `-w` are preserved during an exact restore.
    ///
    /// - Parameters:
    ///   - agentKind: The captured command kind, when known.
    ///   - builtInAgentKind: The exact cmux built-in kind, or `nil` for a custom registration.
    public init(agentKind: String?, builtInAgentKind: String?) {
        var valueOptions: Set<String> = [
            "--cd",
            "--cwd",
            "--work-dir",
            "--workspace",
        ]
        // `--workspace` remains value-matchable, but is intentionally omitted
        // from the unconditional set because its meaning varies by agent (and
        // custom agents may use it as a profile/workspace selector).
        var unconditionallyRemovableValueOptions: Set<String> = [
            "--cd",
            "--cwd",
            "--work-dir",
        ]
        var attachedShortValueOptions: Set<String> = []

        let normalizedBuiltInAgentKind = builtInAgentKind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedBuiltInAgentKind {
        case "codex":
            valueOptions.insert("-C")
            unconditionallyRemovableValueOptions.insert("-C")
            attachedShortValueOptions.insert("-C")
        case "kimi":
            valueOptions.insert("-w")
            unconditionallyRemovableValueOptions.insert("-w")
            attachedShortValueOptions.insert("-w")
        case "qoder":
            // Qoder's --workspace selects a saved workspace; it is not a cwd
            // override even when its value happens to look like a directory.
            valueOptions.remove("--workspace")
            unconditionallyRemovableValueOptions.remove("--workspace")
            valueOptions.insert("-w")
            unconditionallyRemovableValueOptions.insert("-w")
            attachedShortValueOptions.insert("-w")
        case "cursor":
            // Cursor's --workspace selects the cwd. Unlike Qoder's profile
            // selector, it is safe to remove when remote cwd is authoritative.
            unconditionallyRemovableValueOptions.insert("--workspace")
        case .some(_):
            // A caller supplied an identity that is not one of the known
            // built-ins. Retain the conservative legacy `-C` matching only.
            valueOptions.insert("-C")
        case .none:
            // Unknown agents may use `-C` for a non-cwd setting. Keep the
            // legacy value-matching behavior instead of stripping it blindly.
            valueOptions.insert("-C")
        }

        self.valueOptions = valueOptions
        self.unconditionallyRemovableValueOptions = unconditionallyRemovableValueOptions
        self.attachedShortValueOptions = attachedShortValueOptions
    }
}
