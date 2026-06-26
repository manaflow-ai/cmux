import Foundation

/// File-explorer path-string semantics used by ``FileExplorerStore`` to decide
/// whether a selection still lives under a new root and to normalize a requested
/// remote root path. These are pure value transforms with no filesystem access.
extension String {
    /// Interpreting `self` as a candidate filesystem path, returns whether it is
    /// contained in `root`. An empty `root` contains nothing. A `root` of `/`
    /// contains any absolute path (one starting with `/`). Otherwise the candidate
    /// is contained when it equals the root or sits directly beneath it
    /// (`root + "/"` prefix).
    public func isPath(containedIn root: String) -> Bool {
        guard !root.isEmpty else { return false }
        if root == "/" {
            return hasPrefix("/")
        }
        return self == root || hasPrefix(root + "/")
    }

    /// Interpreting `self` as a requested file-explorer root path, returns its
    /// whitespace/newline-trimmed form, or `nil` when the trimmed result is empty.
    /// Call through optional chaining (`maybeRoot?.normalizedFileExplorerRootPath`)
    /// so a `nil` input maps to a `nil` result, matching the original `String?`-in
    /// helper.
    public var normalizedFileExplorerRootPath: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
