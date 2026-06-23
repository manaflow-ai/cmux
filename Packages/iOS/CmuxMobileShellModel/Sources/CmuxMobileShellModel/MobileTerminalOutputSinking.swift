public import CMUXMobileCore
public import Foundation

/// One output chunk yielded to a mounted mobile terminal surface.
public struct MobileTerminalOutputChunk: Sendable {
    /// Raw bytes or a semantic render-grid payload.
    public let payload: MobileTerminalOutputPayload
    /// The active terminal screen captured by the render-grid frame that
    /// produced ``data``. Raw byte fallback chunks carry `nil`.
    public var activeScreen: MobileTerminalRenderGridFrame.Screen? {
        switch payload {
        case .bytes:
            nil
        case .renderGrid(let envelope):
            envelope.frame.activeScreen
        }
    }
    /// Number of scrollback rows included in a full render-grid snapshot.
    /// Delta frames and raw byte fallback chunks carry `nil` because they do not
    /// describe the local mirror's scrollback extent.
    public var scrollbackRows: Int? {
        switch payload {
        case .bytes:
            nil
        case .renderGrid(let envelope):
            envelope.scrollbackRowsForLocalMirror
        }
    }
    /// Viewport grid captured by a full render-grid snapshot. Used by the local
    /// iOS Ghostty mirror to apply final geometry before replaying scrollback.
    public var replayColumns: Int? {
        switch payload {
        case .bytes:
            nil
        case .renderGrid(let envelope):
            envelope.replayGrid?.columns
        }
    }
    /// Viewport row count captured by a full render-grid snapshot.
    public var replayRows: Int? {
        switch payload {
        case .bytes:
            nil
        case .renderGrid(let envelope):
            envelope.replayGrid?.rows
        }
    }
    /// Compatibility byte representation for tests and raw fallback consumers.
    public var data: Data {
        switch payload {
        case .bytes(let data):
            data
        case .renderGrid(let envelope):
            envelope.frame.vtPatchBytes()
        }
    }
    /// Approximate payload byte count for diagnostic logging.
    public var debugByteCount: Int {
        switch payload {
        case .bytes(let data):
            data.count
        case .renderGrid(let envelope):
            envelope.frame.rowSpans.reduce(0) { $0 + $1.text.utf8.count } +
                envelope.frame.scrollbackSpans.reduce(0) { $0 + $1.text.utf8.count }
        }
    }
    /// Token that must be acknowledged after this chunk is applied.
    public let streamToken: UUID

    /// Creates a raw VT byte output chunk.
    public init(
        data: Data,
        streamToken: UUID
    ) {
        self.payload = .bytes(data)
        self.streamToken = streamToken
    }

    /// Creates a semantic render-grid output chunk.
    public init(
        renderGrid envelope: MobileTerminalRenderGridEnvelope,
        streamToken: UUID
    ) {
        self.payload = .renderGrid(envelope)
        self.streamToken = streamToken
    }
}

/// A seam exposing per-surface terminal output as an `AsyncStream`.
///
/// A mounted terminal view obtains the stream for its surface, applies each
/// yielded chunk to the surface renderer, then calls
/// ``terminalOutputDidProcess(surfaceID:streamToken:)``. The bytes are VT patch bytes
/// only for raw PTY compatibility fallback chunks; typed render-grid frames stay
/// semantic through the stream. Obtaining the stream also arms a cold-attach replay so a
/// freshly mounted surface catches up to current state; ending iteration
/// releases the surface so the Mac drops its viewport pin.
///
/// This replaces the previous `(Data) -> Void` sink registry so output
/// propagation is a structured, cancellable `AsyncSequence` instead of a stored
/// callback.
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
