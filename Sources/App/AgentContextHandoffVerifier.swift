import Foundation

/// Verifies that a requested context handoff was durably written before clear.
actor AgentContextHandoffVerifier {
    private static let maximumHandoffBytes = 1_048_576
    /// The outcome of checking one handoff-file request.
    enum Result: String, Sendable {
        /// A regular, non-empty file was modified after the request.
        case written
        /// No file exists at the requested path.
        case missing
        /// The path exists but is not a regular file.
        case notRegularFile
        /// The file exists but contains no meaningful content.
        case empty
        /// The file predates the preservation request.
        case stale
        /// Metadata or contents could not be read safely.
        case unreadable
    }

    /// Checks one handoff path without polling or sleeping.
    ///
    /// The verifier runs on its own actor so synchronous filesystem metadata
    /// and the bounded content read never block the main-actor coordinator.
    /// A pre-existing note is insufficient: its modification date must be
    /// newer than the preservation request.
    ///
    /// - Parameters:
    ///   - path: Local handoff path requested from the managed agent.
    ///   - requestedAt: Main-actor timestamp captured immediately before input.
    /// - Returns: The evidence classification for the requested handoff.
    func verify(path: URL, requestedAt: Date) -> Result {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path.path) else { return .missing }
        guard let attributes = try? fileManager.attributesOfItem(atPath: path.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular else {
            return .notRegularFile
        }
        guard let modificationDate = attributes[.modificationDate] as? Date else {
            return .unreadable
        }
        guard modificationDate > requestedAt else { return .stale }
        guard let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= Self.maximumHandoffBytes else {
            return .unreadable
        }
        guard let data = try? Data(contentsOf: path), !data.isEmpty,
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        return .written
    }
}
