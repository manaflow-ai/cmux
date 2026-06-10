public import Foundation

/// A seam exposing per-surface terminal output as an ordered `AsyncStream` of
/// ``MobileTerminalOutputChunk``.
///
/// A mounted terminal view obtains the stream for its surface, applies each
/// chunk's frame metadata to its local-scroll gates, and feeds the chunk's
/// bytes into its libghostty surface (`process_output`). The bytes are VT
/// patch bytes derived from render-grid frames (with metadata), or raw PTY
/// bytes as a compatibility fallback for older Mac hosts (no metadata).
/// Obtaining the stream also arms a cold-attach replay so a freshly mounted
/// surface catches up to current state; ending iteration releases the surface
/// so the Mac drops its viewport pin.
///
/// This replaces the previous `(Data) -> Void` sink registry so output
/// propagation is a structured, cancellable `AsyncSequence` instead of a stored
/// callback.
public protocol MobileTerminalOutputSinking: Sendable {
    /// The output stream for a terminal surface.
    ///
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Returns: An `AsyncStream` of output chunks (frame metadata + bytes).
    ///   Ending iteration (or cancelling the consuming task) unregisters the
    ///   surface.
    @MainActor func terminalOutputStream(surfaceID: String) -> AsyncStream<MobileTerminalOutputChunk>
}
