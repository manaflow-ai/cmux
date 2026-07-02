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
    /// True when `data` replays a full render-grid snapshot (`ESC c` reset +
    /// scrollback + viewport repaint). The consuming surface must preserve its
    /// local scrollback scroll position across the apply so an authoritative
    /// rebuild never moves the viewport the user is holding.
    public let isFullReplacement: Bool

    public init(
        data: Data,
        streamToken: UUID,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        isFullReplacement: Bool = false
    ) {
        self.data = data
        self.streamToken = streamToken
        self.viewportPolicy = viewportPolicy
        self.isFullReplacement = isFullReplacement
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
