public import CMUXMobileCore
public import Foundation

/// A seam exposing per-surface terminal output as an
/// `AsyncStream<MobileTerminalOutputChunk>`.
///
/// A mounted terminal view obtains the stream for its surface and feeds every
/// yielded chunk into its libghostty surface (`process_output`). Each chunk
/// carries the VT patch bytes (derived from render-grid frames, or raw PTY
/// bytes as a compatibility fallback for older Mac hosts) and, when known, the
/// authoritative Mac grid that produced them so the surface pins its geometry
/// from the same frame whose bytes it applies. Obtaining the stream also arms a
/// cold-attach replay so a freshly mounted surface catches up to current state;
/// ending iteration releases the surface so the Mac drops its viewport pin.
///
/// This replaces the previous `(Data) -> Void` sink registry so output
/// propagation is a structured, cancellable `AsyncSequence` instead of a stored
/// callback.
public protocol MobileTerminalOutputSinking: Sendable {
    /// The output stream for a terminal surface.
    ///
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Returns: An `AsyncStream` of output chunks (bytes plus the optional
    ///   authoritative grid). Ending iteration (or cancelling the consuming
    ///   task) unregisters the surface.
    @MainActor func terminalOutputStream(surfaceID: String) -> AsyncStream<MobileTerminalOutputChunk>
}
