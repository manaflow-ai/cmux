import Foundation

extension RightSidebarMode {
    /// Trim a candidate directory string and treat an all-whitespace or empty
    /// value as `nil`, so a blank directory never counts as a real root.
    static func normalizedDirectory(_ directory: String?) -> String? {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Resolve the directory the Dock panel should root at, preferring the
    /// selected workspace's directory and falling back to the session-index
    /// directory. Both inputs are normalized, so a blank workspace directory
    /// falls through to the fallback.
    public static func dockRootDirectory(workspaceDirectory: String?, fallbackDirectory: String?) -> String? {
        normalizedDirectory(workspaceDirectory) ?? normalizedDirectory(fallbackDirectory)
    }
}
