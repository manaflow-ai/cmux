import Foundation

/// Carries one file mutation reported by an agent transcript.
public struct FileChangePayload: Codable, Hashable, Sendable {
    /// The changed path, when the transcript exposes it.
    public let path: String
    /// The kind of mutation.
    public let changeKind: FileChangeKind
    /// A compact summary of the mutation result, when known.
    public let resultSummary: String?

    private enum CodingKeys: String, CodingKey {
        case path
        case changeKind = "change_kind"
        case resultSummary = "result_summary"
    }

    /// Creates a file change payload.
    /// - Parameters:
    ///   - path: The changed path, when the transcript exposes it.
    ///   - changeKind: The kind of mutation.
    ///   - resultSummary: A compact summary of the mutation result, when known.
    public init(path: String, changeKind: FileChangeKind, resultSummary: String? = nil) {
        self.path = path
        self.changeKind = changeKind
        self.resultSummary = resultSummary
    }
}
