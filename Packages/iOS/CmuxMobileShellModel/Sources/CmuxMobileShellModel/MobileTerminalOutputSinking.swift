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
/// callback.
public struct MobileTerminalOutputChunk: Sendable {
    public let data: Data
    public let streamToken: UUID
    /// Authoritative grid hash stamped by the producer on the render-grid frame
    /// these bytes were synthesized from, or `nil` for raw-byte chunks and
    /// legacy frames. After applying `data`, the surface may verify its grid
    /// against this and record a divergence on a mismatch.
    public let expectedGridHash: UInt64?
    /// Whether these bytes are a full snapshot (a cold attach, resize, screen
    /// transition, or resync), which repaints the whole grid and lands the
    /// viewport at the live bottom. The surface uses this to reset its
    /// scrolled-into-history tracking. `false` for delta and raw-byte chunks.
    public let isFullFrame: Bool
    /// Whether the frame these bytes came from is on the alternate screen, which
    /// has no scrollback, so the viewport is always the live grid. `false` for
    /// raw-byte chunks.
    public let isAlternateScreen: Bool

    /// Creates an output chunk.
    /// - Parameters:
    ///   - data: The VT bytes to feed into `process_output`.
    ///   - streamToken: Token identifying the current output stream, echoed back
    ///     via ``MobileTerminalOutputSinking/terminalOutputDidProcess(surfaceID:streamToken:)``.
    ///   - expectedGridHash: Producer-stamped ``expectedGridHash`` for divergence
    ///     verification, or `nil` for raw-byte and legacy chunks.
    ///   - isFullFrame: Whether these bytes repaint the whole grid (see
    ///     ``isFullFrame``).
    ///   - isAlternateScreen: Whether the source frame is on the alternate screen
    ///     (see ``isAlternateScreen``).
    public init(
        data: Data,
        streamToken: UUID,
        expectedGridHash: UInt64? = nil,
        isFullFrame: Bool = false,
        isAlternateScreen: Bool = false
    ) {
        self.data = data
        self.streamToken = streamToken
        self.expectedGridHash = expectedGridHash
        self.isFullFrame = isFullFrame
        self.isAlternateScreen = isAlternateScreen
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
}
