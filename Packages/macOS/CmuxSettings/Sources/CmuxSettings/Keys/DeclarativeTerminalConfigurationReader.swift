import Foundation

/// Decodes declarative terminal settings away from the main actor.
///
/// JSON parsing and filesystem validation are intentionally isolated here so
/// terminal creation consumes only an already-published snapshot. The reader
/// accepts a validator seam so tests never need to touch the user's filesystem.
public actor DeclarativeTerminalConfigurationReader {
    private let sanitizer: JSONCSanitizer
    private let directoryValidator: @Sendable (String) -> Bool

    /// Creates a reader using the standard JSONC sanitizer and filesystem
    /// validator.
    ///
    /// - Parameters:
    ///   - sanitizer: Sanitizer for comments and trailing commas.
    ///   - directoryValidator: Predicate used to validate an expanded path.
    ///     The default performs a `FileManager` directory check.
    public init(
        sanitizer: JSONCSanitizer = JSONCSanitizer(),
        directoryValidator: @escaping @Sendable (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager().fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    ) {
        self.sanitizer = sanitizer
        self.directoryValidator = directoryValidator
    }

    /// Decodes one coherent store revision into terminal settings.
    ///
    /// - Parameter revision: Immutable bytes from ``JSONConfigStore``.
    /// - Returns: Safe defaults for missing or invalid values.
    public func decode(
        _ revision: JSONConfigStoreSnapshot
    ) -> DeclarativeTerminalConfiguration.Snapshot {
        let configuration = DeclarativeTerminalConfiguration()
        var snapshot = configuration.snapshot(data: revision.data, sanitizer: sanitizer)
        snapshot.fixedPathIsUsable = snapshot.workingDirectoryPolicy == .fixedPath
            && validateFixedPath(snapshot.workingDirectoryPath)
        return snapshot
    }

    /// Validates one fixed path on the reader actor.
    public func validateFixedPath(_ path: String) -> Bool {
        guard let expanded = expandedFixedPath(path) else { return false }
        return directoryValidator(expanded)
    }

    /// Expands and normalizes a fixed path without touching the filesystem.
    public nonisolated func expandedFixedPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard !expanded.isEmpty, (expanded as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
