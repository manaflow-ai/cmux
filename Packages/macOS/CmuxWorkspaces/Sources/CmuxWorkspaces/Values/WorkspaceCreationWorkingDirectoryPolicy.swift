public import Foundation
public import CmuxSettings

/// Selects the concrete working directory for a newly created workspace.
public struct WorkspaceCreationWorkingDirectoryPolicy: Sendable {
    private let policy: NewSurfaceWorkingDirectoryPolicy
    private let fixedPath: String?

    /// Creates a policy from the declarative cmux configuration.
    ///
    /// - Parameters:
    ///   - policy: Configured source for new-surface working directories.
    ///   - fixedPath: Candidate directory used by `fixedPath`.
    public init(
        policy: NewSurfaceWorkingDirectoryPolicy,
        fixedPath: String? = nil
    ) {
        self.policy = policy
        self.fixedPath = fixedPath
    }

    /// Compatibility initializer for the legacy boolean setting. Existing
    /// callers retain their behavior until they opt into the new JSON policy.
    ///
    /// - Parameter inheritanceEnabled: Whether to inherit the active pane or
    ///   use the workspace root.
    public init(inheritanceEnabled: Bool) {
        self.policy = inheritanceEnabled ? .inheritActivePane : .workspaceRoot
        self.fixedPath = nil
    }

    /// Applies creation precedence: an explicit request always wins, then the
    /// configured policy, then a safe workspace-root/default fallback.
    ///
    /// - Parameters:
    ///   - explicitWorkingDirectory: Caller-supplied directory that takes
    ///     precedence over configuration.
    ///   - inheritedWorkingDirectory: Active-pane directory considered by
    ///     `inheritActivePane`.
    ///   - defaultWorkingDirectory: Lazily evaluated final fallback.
    ///   - workspaceRootWorkingDirectory: Immutable workspace root, when the
    ///     caller has one.
    ///   - fileManager: Filesystem used to validate a fixed path.
    /// - Returns: A non-empty concrete working-directory path.
    public func resolve(
        explicitWorkingDirectory: String?,
        inheritedWorkingDirectory: String?,
        defaultWorkingDirectory: @autoclosure () -> String,
        workspaceRootWorkingDirectory: String? = nil,
        fileManager: FileManager = .default
    ) -> String {
        if let explicitWorkingDirectory = normalized(explicitWorkingDirectory) {
            return explicitWorkingDirectory
        }

        let root = normalized(workspaceRootWorkingDirectory)
            ?? normalized(defaultWorkingDirectory())
            ?? "/"
        switch policy {
        case .inheritActivePane:
            return normalized(inheritedWorkingDirectory) ?? root
        case .workspaceRoot:
            return root
        case .fixedPath:
            guard let fixedPath = expandedFixedPath(),
                  isUsableDirectory(fixedPath, fileManager: fileManager) else {
                return root
            }
            return fixedPath
        }
    }

    private func expandedFixedPath() -> String? {
        guard let fixedPath = normalized(fixedPath) else { return nil }
        let expanded = (fixedPath as NSString).expandingTildeInPath
        guard !expanded.isEmpty, (expanded as NSString).isAbsolutePath else { return nil }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        return url.path
    }

    private func isUsableDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
