import Foundation

/// Selects the concrete working directory for a newly created workspace.
public enum WorkspaceCreationWorkingDirectoryPolicy {
    /// Applies workspace-creation precedence without allowing disabled
    /// inheritance to collapse into an ambiguous `nil` terminal override.
    public static func resolve(
        explicitWorkingDirectory: String?,
        inheritedWorkingDirectory: String?,
        inheritanceEnabled: Bool,
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

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
