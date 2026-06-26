import Foundation

/// Path-string formatting shared by the text-box mention scanners (file mentions
/// and `SKILL.md` discovery). These are the single source of truth for turning an
/// absolute filesystem path into the relative form used as a candidate title and
/// the `~`-abbreviated form used as a candidate subtitle.
extension String {
    /// Interpreting `self` as an absolute filesystem path, returns it relative to
    /// `rootPath`. Paths outside the root are returned unchanged; a path equal to
    /// the root collapses to its last path component.
    public func pathRelative(toRoot rootPath: String) -> String {
        guard hasPrefix(rootPath) else { return self }
        let start = index(startIndex, offsetBy: rootPath.count)
        let relative = String(self[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? URL(fileURLWithPath: self).lastPathComponent : relative
    }

    /// Interpreting `self` as an absolute filesystem path, returns it with the
    /// current user's home directory replaced by `~`. Paths outside home are
    /// returned unchanged.
    public var homeAbbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard hasPrefix(home) else { return self }
        return "~" + String(dropFirst(home.count))
    }
}
