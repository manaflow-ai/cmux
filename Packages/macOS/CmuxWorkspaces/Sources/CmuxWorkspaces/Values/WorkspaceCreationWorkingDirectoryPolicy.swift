import Foundation

/// Selects the concrete working directory for a newly created workspace.
public struct WorkspaceCreationWorkingDirectoryPolicy: Sendable {
    private let inheritanceEnabled: Bool

    /// Creates a policy for the current workspace inheritance preference.
    public init(inheritanceEnabled: Bool) {
        self.inheritanceEnabled = inheritanceEnabled
    }

    /// Applies workspace-creation precedence without allowing disabled
    /// inheritance to collapse into an ambiguous `nil` terminal override.
    public func resolve(
        explicitWorkingDirectory: String?,
        inheritedWorkingDirectory: String?,
        defaultWorkingDirectory: @autoclosure () -> String
    ) -> String {
        if let explicitWorkingDirectory = normalized(explicitWorkingDirectory) {
            return explicitWorkingDirectory
        }
        if inheritanceEnabled,
           let inheritedWorkingDirectory = normalized(inheritedWorkingDirectory) {
            return inheritedWorkingDirectory
        }
        return normalized(defaultWorkingDirectory()) ?? "/"
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
