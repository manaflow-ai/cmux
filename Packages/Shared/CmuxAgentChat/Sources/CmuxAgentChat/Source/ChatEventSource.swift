import Foundation

/// The seam between chat surfaces and whatever produces conversation data.
///
/// ``ChatConversationStore`` depends only on this protocol. On iOS the
/// implementation adapts the mobile RPC client; a future macOS surface can
/// implement it in-process against the host's own transcript service. Test
/// and preview surfaces use ``FixtureChatEventSource``.
public protocol ChatEventSource: Sendable {
    /// Whether this source supports Mac-hosted artifact preview RPCs.
    var supportsArtifacts: Bool { get }
    /// Whether this source supports recursive artifact folder browsing.
    var supportsArtifactFolders: Bool { get }

    /// Fetches a page of transcript history for a session.
    ///
    /// - Parameters:
    ///   - sessionID: The session to read.
    ///   - beforeSeq: Return only messages with seq strictly below this
    ///     cursor; `nil` returns the newest page.
    ///   - limit: Maximum number of messages to return.
    /// - Returns: The page, ordered by ascending seq.
    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage

    /// Opens the live event stream for a session.
    ///
    /// The stream finishes when the underlying connection closes; callers
    /// re-subscribe after reconnect. Implementations honor stream
    /// termination (consumer cancellation) by tearing down their
    /// subscription.
    ///
    /// - Parameter sessionID: The session to observe.
    /// - Returns: Live updates, in delivery order.
    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent>

    /// Sends a user prompt (and optional attachments) to the session.
    ///
    /// Attachments are delivered to the host first so the prompt can
    /// reference them; the text is then injected into the agent's terminal.
    ///
    /// - Parameters:
    ///   - text: The prompt text.
    ///   - attachments: Images to deliver ahead of the prompt.
    ///   - sessionID: The destination session.
    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws

    /// Interrupts the session's agent.
    ///
    /// - Parameters:
    ///   - sessionID: The session to interrupt.
    ///   - hard: `false` sends the agent's polite interrupt (Esc);
    ///     `true` sends a hard interrupt (ctrl-C).
    func interrupt(sessionID: String, hard: Bool) async throws

    /// Answers a pending in-terminal choice (question option or permission
    /// button) by its display index.
    ///
    /// Implementations translate the index into whatever the agent's
    /// terminal UI expects (number key, arrow + return).
    ///
    /// - Parameters:
    ///   - optionIndex: Zero-based index of the chosen option.
    ///   - sessionID: The session being answered.
    func answer(optionIndex: Int, sessionID: String) async throws

    /// Fetches metadata for a referenced artifact path.
    ///
    /// - Parameters:
    ///   - sessionID: The session whose transcript referenced the path.
    ///   - path: Absolute Mac host path.
    /// - Returns: Artifact metadata.
    func artifactStat(sessionID: String, path: String) async throws -> ChatArtifactStat

    /// Fetches all bytes for a referenced artifact path.
    ///
    /// - Parameters:
    ///   - sessionID: The session whose transcript referenced the path.
    ///   - path: Absolute Mac host path.
    ///   - progress: Optional byte-progress callback.
    /// - Returns: Raw file bytes.
    func artifactFetch(
        sessionID: String,
        path: String,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
    ) async throws -> Data

    /// Streams raw chunks for a referenced artifact path.
    ///
    /// Implementations call `onChunk` in byte-offset order and await it before
    /// requesting the next chunk, so cancellation and consumer backpressure
    /// remain part of the fetch task.
    ///
    /// - Parameters:
    ///   - sessionID: The session whose transcript referenced the path.
    ///   - path: Absolute Mac host path.
    ///   - onChunk: Structured callback for each fetched chunk.
    func artifactFetch(
        sessionID: String,
        path: String,
        onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws

    /// Fetches a JPEG thumbnail for a referenced image artifact.
    ///
    /// - Parameters:
    ///   - sessionID: The session whose transcript referenced the path.
    ///   - path: Absolute Mac host path.
    ///   - maxDimension: Maximum thumbnail pixel width or height.
    /// - Returns: JPEG thumbnail data and dimensions.
    func artifactThumbnail(
        sessionID: String,
        path: String,
        maxDimension: Int
    ) async throws -> ChatArtifactThumbnail

    /// Lists immediate entries in a referenced artifact directory.
    ///
    /// - Parameters:
    ///   - sessionID: The session whose transcript referenced the directory.
    ///   - path: Absolute Mac host directory path.
    /// - Returns: A capped directory listing.
    func artifactList(sessionID: String, path: String) async throws -> ChatArtifactDirectoryListing
}

public extension ChatEventSource {
    /// Unsupported-by-default artifact capability for fixtures and previews.
    var supportsArtifacts: Bool { false }

    /// Unsupported-by-default recursive artifact folder capability.
    var supportsArtifactFolders: Bool { false }

    /// Unsupported-by-default artifact stat implementation.
    func artifactStat(sessionID: String, path: String) async throws -> ChatArtifactStat {
        throw ChatArtifactError.unsupported
    }

    /// Unsupported-by-default artifact fetch implementation.
    func artifactFetch(
        sessionID: String,
        path: String,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) async throws -> Data {
        throw ChatArtifactError.unsupported
    }

    /// Whole-file fallback for sources that have not adopted chunk streaming.
    func artifactFetch(
        sessionID: String,
        path: String,
        onChunk: @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws {
        let data = try await artifactFetch(sessionID: sessionID, path: path, progress: nil)
        try Task.checkCancellation()
        try await onChunk(
            ChatArtifactChunk(
                data: data,
                offset: 0,
                totalSize: Int64(data.count),
                eof: true
            )
        )
    }

    /// Unsupported-by-default artifact thumbnail implementation.
    func artifactThumbnail(
        sessionID: String,
        path: String,
        maxDimension: Int
    ) async throws -> ChatArtifactThumbnail {
        throw ChatArtifactError.unsupported
    }

    /// Unsupported-by-default artifact directory-list implementation.
    func artifactList(sessionID: String, path: String) async throws -> ChatArtifactDirectoryListing {
        throw ChatArtifactError.unsupported
    }
}
