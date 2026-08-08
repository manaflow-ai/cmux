import Foundation

/// Describes agent argv options that carry a working-directory value.
public struct AgentWorkingDirectoryOptionPolicy: Sendable {
    /// Options whose cwd value is stored in the following token or after `=`.
    public let valueOptions: Set<String>
    /// Short options whose cwd value may be attached to the option token.
    public let attachedShortValueOptions: Set<String>

    /// Creates the option policy for an agent kind.
    ///
    /// Ambiguous short options are enabled only for agents where their cwd meaning is known.
    /// An unknown kind retains legacy split `-C <cwd>` matching, but does not interpret an
    /// arbitrary token beginning with `-C` as an attached cwd value.
    ///
    /// - Parameter agentKind: The normalized agent kind, when known.
    public init(agentKind: String? = nil) {
        var valueOptions: Set<String> = [
            "--cd",
            "--cwd",
            "--work-dir",
            "--workspace",
        ]
        var attachedShortValueOptions: Set<String> = []

        switch agentKind?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "codex":
            valueOptions.insert("-C")
            attachedShortValueOptions.insert("-C")
        case "kimi", "qoder":
            valueOptions.insert("-w")
            attachedShortValueOptions.insert("-w")
        case .some(_):
            valueOptions.insert("-C")
        case .none:
            valueOptions.insert("-C")
        }

        self.valueOptions = valueOptions
        self.attachedShortValueOptions = attachedShortValueOptions
    }
}
