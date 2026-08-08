import Foundation

/// A Cursor CLI transcript discovered in Cursor's local project store.
public struct CursorIndexedSession: Equatable, Sendable {
    /// Cursor's native session identifier.
    public let sessionID: String
    /// The first user message, or hook-provided title when the transcript has no user text.
    public let title: String
    /// The launch directory captured by cmux's Cursor hook, when available.
    public let workingDirectory: String?
    /// The most recent transcript or hook-store activity time.
    public let modifiedAt: Date
    /// The JSONL transcript used for Vault search and preview.
    public let transcriptURL: URL

    /// Creates a discovered Cursor session.
    ///
    /// - Parameters:
    ///   - sessionID: Cursor's native session identifier.
    ///   - title: The display title derived from the first user message or hook metadata.
    ///   - workingDirectory: The captured launch directory, if known.
    ///   - modifiedAt: The latest known activity time.
    ///   - transcriptURL: The local JSONL transcript URL.
    public init(
        sessionID: String,
        title: String,
        workingDirectory: String?,
        modifiedAt: Date,
        transcriptURL: URL
    ) {
        self.sessionID = sessionID
        self.title = title
        self.workingDirectory = workingDirectory
        self.modifiedAt = modifiedAt
        self.transcriptURL = transcriptURL
    }
}
