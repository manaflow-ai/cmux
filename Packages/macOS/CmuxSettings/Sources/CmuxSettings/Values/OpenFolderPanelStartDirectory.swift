import Foundation

/// Picks the folder the Open Folder panel starts in.
///
/// `app.defaultWorkspacePath` pins it (#3156). When that is empty or does
/// not name an existing directory, the panel starts in the active
/// workspace's directory, as before.
public enum OpenFolderPanelStartDirectory {
    public static func resolve(
        configuredPath: String,
        workspaceDirectory: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        isDirectory: (String) -> Bool = OpenFolderPanelStartDirectory.isExistingDirectory
    ) -> URL? {
        if let path = expandedPath(configuredPath, environment: environment, homeDirectory: homeDirectory),
           isDirectory(path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let workspaceDirectory, !workspaceDirectory.isEmpty {
            return URL(fileURLWithPath: workspaceDirectory, isDirectory: true)
        }
        return nil
    }

    /// Expands a leading `~` and `$VAR` / `${VAR}` references. Returns nil
    /// for an empty value, an unset variable, or a path that is not absolute
    /// after expansion.
    static func expandedPath(
        _ rawPath: String,
        environment: [String: String],
        homeDirectory: String
    ) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var path = expandingEnvironmentVariables(in: trimmed, environment: environment)
        else { return nil }
        if path == "~" {
            path = homeDirectory
        } else if path.hasPrefix("~/") {
            path = homeDirectory + String(path.dropFirst())
        }
        guard path.hasPrefix("/") else { return nil }
        return path
    }

    private static func expandingEnvironmentVariables(
        in path: String,
        environment: [String: String]
    ) -> String? {
        guard path.contains("$") else { return path }
        let pattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = path as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: path, range: NSRange(location: 0, length: source.length)) {
            let nameRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let value = environment[source.substring(with: nameRange)], !value.isEmpty else { return nil }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += value
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    public static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
