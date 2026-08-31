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
        var valueOptions: Set<String> = [
            "--cd",
            "--cwd",
            "--work-dir",
            "--workspace",
        ]
        var unconditionallyRemovableValueOptions = valueOptions
        var attachedShortValueOptions: Set<String> = []

        switch agentKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
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
        case .some(_):
            // Unknown agents may use `-C` for a non-cwd setting. Keep the
            // legacy value-matching behavior instead of stripping it blindly.
            valueOptions.insert("-C")
        case .none:
            // Without an agent kind, `-C` remains ambiguous as well.
            valueOptions.insert("-C")
        }

        self.valueOptions = valueOptions
        self.unconditionallyRemovableValueOptions = unconditionallyRemovableValueOptions
        self.attachedShortValueOptions = attachedShortValueOptions
    }
}
