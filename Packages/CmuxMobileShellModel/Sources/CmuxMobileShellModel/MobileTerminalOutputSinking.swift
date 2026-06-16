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
/// callback.
public struct MobileTerminalOutputChunk: Sendable {
    /// The active terminal screen captured by the render-grid frame that
    /// produced ``data``. Raw byte fallback chunks carry `nil`.
    public let activeScreen: MobileTerminalRenderGridFrame.Screen?
    /// Number of scrollback rows included in a full render-grid snapshot.
    /// Delta frames and raw byte fallback chunks carry `nil` because they do not
    /// describe the local mirror's scrollback extent.
    public let scrollbackRows: Int?
    /// Viewport grid captured by a full render-grid snapshot. Used by the local
    /// iOS Ghostty mirror to apply final geometry before replaying scrollback.
    public let replayColumns: Int?
    public let replayRows: Int?
    public let data: Data
    public let streamToken: UUID

    public init(
        data: Data,
        streamToken: UUID,
        activeScreen: MobileTerminalRenderGridFrame.Screen? = nil,
        scrollbackRows: Int? = nil,
        replayColumns: Int? = nil,
        replayRows: Int? = nil
    ) {
        self.activeScreen = activeScreen
        self.scrollbackRows = scrollbackRows
        self.replayColumns = replayColumns
        self.replayRows = replayRows
        self.data = data
        self.streamToken = streamToken
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
