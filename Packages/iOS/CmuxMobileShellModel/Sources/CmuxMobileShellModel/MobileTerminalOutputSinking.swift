public import CMUXMobileCore
public import Foundation

/// A seam exposing per-surface terminal output as an `AsyncStream`.
///
/// A mounted terminal view obtains the stream for its surface, feeds each
/// yielded chunk into its libghostty surface (`process_output`), then calls
/// ``terminalOutputDidProcess(surfaceID:streamToken:)``. The bytes are VT patch bytes
/// derived from render-grid frames, or raw PTY bytes as a compatibility fallback
/// for older Mac hosts. Obtaining the stream also arms a cold-attach replay so a
/// freshly mounted surface catches up to current state; ending iteration
/// releases the surface so the Mac drops its viewport pin.
///
/// This replaces the previous `(Data) -> Void` sink registry so output
/// propagation is a structured, cancellable `AsyncSequence` instead of a stored
/// callback. Chunks may also carry a viewport policy so primary-screen output can
/// use the phone's natural height while alternate-screen replay remains pinned
/// to the remote grid.
public enum MobileTerminalOutputViewportPolicy: Equatable, Sendable {
    case natural
    case remoteGrid(columns: Int, rows: Int)
}

public struct MobileTerminalOutputChunk: Sendable {
    public let data: Data
    public let streamToken: UUID
    public let viewportPolicy: MobileTerminalOutputViewportPolicy?
    /// Source grid whose VT replay bytes are carried by this chunk.
    public let sourceRenderGridFrame: MobileTerminalRenderGridFrame?
    /// Terminal byte high-water mark represented by this chunk, when known.
    public let endSequence: UInt64?
    /// Whether nonempty output must pass render-grid verification before display.
    public let requiresVerifiedReplay: Bool
    /// Whether the consumer must discard any prior verified presentation before
    /// applying this chunk through the legacy compatibility path.
    ///
    /// Retry-exhaustion replacements are deliberately unverified byte snapshots.
    /// A verifier that keeps its previous grid baseline can reject the next live
    /// delta or reveal stale frozen pixels, so the UI starts a fresh full-frame
    /// verification generation when this flag is set.
    public let requiresVerifiedReplayReset: Bool
    /// Raw Ghostty defaults that must be installed before this chunk's VT replay.
    public let terminalConfigTheme: TerminalTheme?

    /// Creates one backpressured terminal-output chunk.
    ///
    /// - Parameters:
    ///   - data: VT or PTY bytes to apply.
    ///   - streamToken: Identity of the mounted output stream.
    ///   - viewportPolicy: Optional viewport policy to apply with the bytes.
    ///   - sourceRenderGridFrame: Source grid represented by the bytes.
    ///   - endSequence: Terminal byte high-water mark represented by the chunk.
    ///   - requiresVerifiedReplay: Whether the verified replay path is required.
    ///   - requiresVerifiedReplayReset: Whether a stale verified presentation
    ///     must be cleared before applying this compatibility chunk.
    ///   - terminalConfigTheme: Raw Ghostty defaults paired with the bytes.
    public init(
        data: Data,
        streamToken: UUID,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        sourceRenderGridFrame: MobileTerminalRenderGridFrame? = nil,
        endSequence: UInt64? = nil,
        requiresVerifiedReplay: Bool = false,
        requiresVerifiedReplayReset: Bool = false,
        terminalConfigTheme: TerminalTheme? = nil
    ) {
        self.data = data
        self.streamToken = streamToken
        self.viewportPolicy = viewportPolicy
        self.sourceRenderGridFrame = sourceRenderGridFrame
        self.endSequence = endSequence
        self.requiresVerifiedReplay = requiresVerifiedReplay
        self.requiresVerifiedReplayReset = requiresVerifiedReplayReset
        self.terminalConfigTheme = terminalConfigTheme
    }
}

public protocol MobileTerminalOutputSinking: Sendable {
    /// The output byte stream for a terminal surface.
    ///
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Returns: An `AsyncStream` of output chunks. Ending iteration (or
    ///   cancelling the consuming task) unregisters the surface.
    @MainActor func terminalOutputStream(surfaceID: String) -> AsyncStream<MobileTerminalOutputChunk>

    /// Mark the current yielded chunk as applied, allowing the next buffered
    /// chunk for the same surface to be yielded.
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Parameter streamToken: The token carried by the yielded chunk.
    @MainActor func terminalOutputDidProcess(surfaceID: String, streamToken: UUID)

    /// Abandon the current yielded chunk after the local renderer was reset.
    ///
    /// The sink must drop stale pending output, invalidate the old stream token,
    /// and request an authoritative replay for the same surface.
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Parameter streamToken: The token carried by the abandoned chunk.
    @MainActor func terminalOutputDidReset(surfaceID: String, streamToken: UUID)

    /// Request an authoritative replay without an abandoned in-flight chunk.
    /// - Parameter surfaceID: The terminal surface identifier.
    @MainActor func terminalOutputNeedsReplay(surfaceID: String)
}
