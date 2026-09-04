public import Foundation

/// Verifies that a requested context handoff was durably written before clear.
public actor AgentContextHandoffVerifier {
    private static let maximumHandoffBytes = 1_048_576
    private let fileSystem: any AgentContextHandoffFileSystem

    /// The outcome of checking one handoff-file request.
    public enum Result: String, Equatable, Sendable {
        /// A regular, non-empty file was modified after the request or differs
        /// from the descriptor-bound pre-request baseline.
        case written
        /// No file exists at the requested path.
        case missing
        /// The path exists but is not a regular file.
        case notRegularFile
        /// The file exists but contains no meaningful content.
        case empty
        /// The file is unchanged from the pre-request baseline or predates the
        /// preservation request when no baseline was supplied.
        case stale
        /// Metadata or contents could not be read safely.
        case unreadable
    }

    /// Creates a verifier backed by the live local filesystem.
    public init() {
        self.fileSystem = LiveAgentContextHandoffFileSystem()
    }

    /// Creates a verifier with an injected filesystem boundary.
    ///
    /// - Parameter fileSystem: Metadata and bounded-read implementation used
    ///   by verification. Tests can provide deterministic failures and races.
    init(fileSystem: any AgentContextHandoffFileSystem) {
        self.fileSystem = fileSystem
    }

    /// Captures the descriptor-bound handoff identity immediately before a
    /// preservation request is sent.
    ///
    /// A missing file is a valid baseline: the provider may create it in
    /// response to the request. Any other read/metadata failure is retained as
    /// ``AgentContextHandoffVerificationBaseline/unavailable`` so a later
    /// destructive clear fails closed.
    ///
    /// - Parameter path: Local handoff path requested from the managed agent.
    /// - Returns: The baseline evidence to pass to ``verify(path:requestedAt:baseline:)``.
    public func capture(path: URL) async -> AgentContextHandoffVerificationBaseline {
        do {
            guard let snapshot = try await fileSystem.readSnapshot(
                at: path,
                maximumBytes: Self.maximumHandoffBytes
            ) else {
                return .missing
            }
            guard Self.isUsableSnapshot(snapshot) else { return .unavailable }
            return .existing(snapshot.fingerprint())
        } catch {
            return .unavailable
        }
    }

    /// Checks one handoff path without polling or sleeping.
    ///
    /// The verifier runs on its own actor so synchronous filesystem metadata
    /// and the bounded content read never block the main-actor coordinator.
    /// A pre-existing note is insufficient: when a baseline is supplied, the
    /// post-request descriptor-bound identity/content snapshot must differ from
    /// it. This avoids rejecting valid writes on filesystems whose mtime is
    /// coarser than the request clock. Without a baseline, the legacy strict
    /// mtime check remains in force.
    ///
    /// - Parameters:
    ///   - path: Local handoff path requested from the managed agent.
    ///   - requestedAt: Main-actor timestamp captured immediately before input.
    ///   - baseline: Optional descriptor-bound pre-request evidence. Pass the
    ///     result of ``capture(path:)`` for coarse-mtime-safe verification.
    /// - Returns: The evidence classification for the requested handoff.
    public func verify(
        path: URL,
        requestedAt: Date,
        baseline: AgentContextHandoffVerificationBaseline? = nil
    ) async -> Result {
        let snapshot: AgentContextHandoffFileSnapshot
        do {
            guard let value = try await fileSystem.readSnapshot(
                at: path,
                maximumBytes: Self.maximumHandoffBytes
            ) else {
                return .missing
            }
            snapshot = value
        } catch {
            return .unreadable
        }
        let metadata = snapshot.metadata
        guard metadata.isRegularFile else { return .notRegularFile }
        guard Self.isUsableSnapshot(snapshot) else { return .unreadable }

        if let baseline {
            switch baseline {
            case .missing:
                // No pre-request identity was available. Creation-time mtime
                // remains the only evidence that this file belongs to the
                // current request; retain the strict clock check for this
                // case to avoid accepting an unrelated race-created file.
                guard let modificationDate = metadata.modificationDate,
                      modificationDate > requestedAt else {
                    return .stale
                }
            case .existing(let previous):
                // Compare identity and a SHA-256 content digest. Either an
                // atomic replacement or an in-place rewrite is meaningful
                // evidence, even when wall-clock mtimes are equal.
                guard snapshot.fingerprint() != previous else { return .stale }
            case .unavailable:
                return .unreadable
            }
        } else {
            guard let modificationDate = metadata.modificationDate,
                  modificationDate > requestedAt else {
                return .stale
            }
        }

        let data = snapshot.data
        guard !data.isEmpty else { return .empty }
        guard let text = String(data: data, encoding: .utf8) else {
            return .unreadable
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .empty
            : .written
    }

    private static func isUsableSnapshot(_ snapshot: AgentContextHandoffFileSnapshot) -> Bool {
        let metadata = snapshot.metadata
        guard metadata.isRegularFile,
              metadata.modificationDate != nil,
              metadata.size >= 0,
              metadata.size <= Self.maximumHandoffBytes,
              snapshot.data.count <= Self.maximumHandoffBytes else {
            return false
        }
        return true
    }
}
