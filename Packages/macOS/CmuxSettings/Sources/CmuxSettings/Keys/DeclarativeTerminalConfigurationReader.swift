import Foundation

/// Decodes declarative terminal settings away from the main actor.
///
/// JSON parsing is intentionally isolated here so terminal creation consumes
/// only the already-published cache value. A reader is cheap to construct and
/// can be injected into tests or a settings runtime.
public actor DeclarativeTerminalConfigurationReader {
    private let sanitizer: JSONCSanitizer

    /// Creates a reader using the standard JSONC sanitizer.
    ///
    /// - Parameter sanitizer: Sanitizer for comments and trailing commas.
    public init(sanitizer: JSONCSanitizer = JSONCSanitizer()) {
        self.sanitizer = sanitizer
    }

    /// Decodes one coherent store revision into terminal settings.
    ///
    /// - Parameter revision: Immutable bytes from ``JSONConfigStore``.
    /// - Returns: Safe defaults for missing or invalid values.
    public func decode(
        _ revision: JSONConfigStoreSnapshot
    ) -> DeclarativeTerminalConfiguration.Snapshot {
        var snapshot = DeclarativeTerminalConfiguration.snapshot(
            data: revision.data,
            sanitizer: sanitizer
        )
        snapshot.fixedPathIsUsable = snapshot.workingDirectoryPolicy == .fixedPath
            && Self.isUsableDirectory(snapshot.workingDirectoryPath)
        return snapshot
    }

    /// Validates one fixed path on the reader actor.
    public func validateFixedPath(_ path: String) -> Bool {
        Self.isUsableDirectory(path)
    }

    /// Expands and normalizes a fixed path without touching the filesystem.
    public nonisolated static func expandedFixedPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard !expanded.isEmpty, (expanded as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Validates a configured fixed path on this reader actor, keeping
    /// filesystem metadata lookup off the main actor's surface-creation path.
    private static func isUsableDirectory(_ path: String) -> Bool {
        guard let expanded = expandedFixedPath(path) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
