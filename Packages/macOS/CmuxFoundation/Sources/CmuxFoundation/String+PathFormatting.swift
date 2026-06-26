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

    /// Interpreting `self` as an absolute filesystem path, returns the form shown
    /// to the user relative to an explicit `homePath` (which may be a remote home
    /// for an SSH provider). A path equal to home collapses to `~`, a path under
    /// home becomes `~/<remainder>`, and anything else (including a `nil`/empty
    /// home) is returned verbatim. Trailing slashes on either side are ignored
    /// when matching, but the original (unnormalized) string is returned for
    /// non-matches.
    public func homeRelativeDisplayPath(homePath: String?) -> String {
        guard let home = homePath, !home.isEmpty else { return self }
        let normalizedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        let normalizedPath = hasSuffix("/") ? String(dropLast()) : self
        if normalizedPath == normalizedHome {
            return "~"
        }
        let homePrefix = normalizedHome + "/"
        if normalizedPath.hasPrefix(homePrefix) {
            return "~/" + normalizedPath.dropFirst(homePrefix.count)
        }
        return self
    }

    /// Interpreting `self` as a filesystem path, returns its canonical absolute
    /// path when it names an existing directory, or `nil` otherwise. The path is
    /// trimmed of surrounding whitespace and newlines, tilde-expanded, and
    /// standardized; an empty (post-trim) path, a non-existent path, or a path that
    /// is not a directory yields `nil`. Call through optional chaining
    /// (`maybePath?.canonicalDirectoryPath()`) so a `nil` input maps to a `nil`
    /// result, matching the original `String?`-in helper. `fileManager` is injected
    /// for testability and defaults to `.default`.
    public func canonicalDirectoryPath(fileManager: FileManager = .default) -> String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url.path
    }
}
