import Foundation

/// Sanitized recovery text shared by the native restore presentation and the CLI.
public struct CodexWriterRestoreNotice: Sendable {
    /// Creates a localized notice formatter.
    public init() {}

    /// Formats a held-lock diagnostic without account paths or conversation identifiers.
    /// - Parameter candidates: Best-effort observations, never signal authority.
    /// - Returns: Recovery guidance plus candidate process identifiers when available.
    public func message(candidates: [CodexWriterProcessInspector.Candidate]) -> String {
        let message = String(
            localized: "agentRestore.writerLock.held",
            defaultValue: "This conversation is in use by another process. Continue there or close it normally, then retry restoring it here."
        )
        guard !candidates.isEmpty else { return message }
        let names = candidates.map { "\($0.processID) (\($0.name))" }.joined(separator: ", ")
        let format = String(localized: "agentRestore.writerLock.candidates", defaultValue: "Possible owners: %1$@.")
        return message + "\n" + String(format: format, locale: Locale(identifier: "en_US_POSIX"), names)
    }
}
