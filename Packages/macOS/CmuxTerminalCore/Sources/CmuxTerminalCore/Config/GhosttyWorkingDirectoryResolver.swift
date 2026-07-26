import Foundation

/// Resolves Ghostty's `working-directory` config value into the concrete path
/// required by cmux when it must suppress Ghostty's focused-surface inheritance.
public enum GhosttyWorkingDirectoryResolver {
    /// Resolves using the current user's home directory and the process cwd.
    public static func resolve(configuredValue: String?) -> String {
        resolve(
            configuredValue: configuredValue,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            processWorkingDirectory: FileManager.default.currentDirectoryPath
        )
    }

    /// Returns a concrete absolute working directory for a new terminal.
    ///
    /// Ghostty normally resolves `home` and `inherit` while finalizing its
    /// runtime config. Embedded surfaces cannot rely on that default when their
    /// creation context would first inherit another surface's live directory,
    /// so cmux resolves those values before passing the surface override.
    public static func resolve(
        configuredValue: String?,
        homeDirectory: String,
        processWorkingDirectory: String
    ) -> String {
        let home = normalizedAbsolutePath(homeDirectory) ?? "/"
        let processDirectory = normalizedAbsolutePath(processWorkingDirectory) ?? home
        guard let configuredValue = normalizedValue(configuredValue) else {
            return home
        }

        switch configuredValue {
        case "home":
            return home
        case "inherit":
            return processDirectory
        default:
            if configuredValue.hasPrefix("~/") {
                let relativePath = String(configuredValue.dropFirst(2))
                return (home as NSString).appendingPathComponent(relativePath)
            }
            return normalizedAbsolutePath(configuredValue) ?? home
        }
    }

    private static func normalizedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedAbsolutePath(_ value: String) -> String? {
        guard let value = normalizedValue(value), value.hasPrefix("/") else {
            return nil
        }
        return value
    }
}
