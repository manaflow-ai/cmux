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
    /// VT/PTY bytes to feed into the mounted terminal surface.
    public let data: Data
    /// Stream generation token used to reject acknowledgements from stale mounts.
    public let streamToken: UUID
    /// Whether the local emulator must keep the producer's grid before applying
    /// this chunk.
    ///
    /// Legacy raw-byte output is produced by the Mac PTY at the negotiated
    /// effective grid, so iOS must preserve that grid while applying it. Render-grid
    /// output is already viewport-shaped state and can fill the local container.
    public let preservesProducerGrid: Bool

    public init(data: Data, streamToken: UUID, preservesProducerGrid: Bool = false) {
        self.data = data
        self.streamToken = streamToken
        self.preservesProducerGrid = preservesProducerGrid
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
