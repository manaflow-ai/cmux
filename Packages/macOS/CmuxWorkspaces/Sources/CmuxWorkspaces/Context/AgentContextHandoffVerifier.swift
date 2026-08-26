public import Foundation

/// Verifies that a requested context handoff was durably written before clear.
public actor AgentContextHandoffVerifier {
    private static let maximumHandoffBytes = 1_048_576
    private let fileSystem: any AgentContextHandoffFileSystem

    /// The outcome of checking one handoff-file request.
    public enum Result: String, Equatable, Sendable {
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

    /// Creates a verifier backed by the live local filesystem.
    public init() {
        self.fileSystem = LiveAgentContextHandoffFileSystem(
            fileManager: FileManager()
        )
    }

    /// Creates a verifier with an injected filesystem boundary.
    ///
    /// - Parameter fileSystem: Metadata and bounded-read implementation used
    ///   by verification. Tests can provide deterministic failures and races.
    init(fileSystem: any AgentContextHandoffFileSystem) {
        self.fileSystem = fileSystem
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
    public func verify(path: URL, requestedAt: Date) async -> Result {
        let metadata: AgentContextHandoffFileMetadata
        do {
            guard let value = try await fileSystem.metadata(for: path) else {
                return .missing
            }
            metadata = value
        } catch {
            return .unreadable
        }
        guard metadata.isRegularFile else { return .notRegularFile }
        guard let modificationDate = metadata.modificationDate else {
            return .unreadable
        }
        guard modificationDate > requestedAt else { return .stale }
        guard metadata.size > 0,
              metadata.size <= Self.maximumHandoffBytes else {
            return .unreadable
        }
        let data: Data
        do {
            data = try await fileSystem.readData(
                at: path,
                maximumBytes: Self.maximumHandoffBytes
            )
        } catch {
            return .unreadable
        }
        guard data.count <= Self.maximumHandoffBytes else { return .unreadable }
        guard !data.isEmpty else { return .empty }
        guard let text = String(data: data, encoding: .utf8) else {
            return .unreadable
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .empty
            : .written
    }
}
