public import Foundation

/// The shared Metal-event generation and value completed for one frame.
public struct TerminalRenderCompletionFence: Equatable, Sendable {
    /// Identity of the shared event imported through the renderer control plane.
    public let eventID: UUID

    /// The event value that must be signaled before presentation.
    public let value: UInt64

    /// Creates a completion fence.
    ///
    /// - Parameters:
    ///   - eventID: Identity of the out-of-band shared Metal event.
    ///   - value: A nonzero value signaled for this frame.
    /// - Throws: ``TerminalRenderFrameProtocolError/invalidCompletionFence`` for zero.
    public init(eventID: UUID, value: UInt64) throws {
        guard value > 0 else {
            throw TerminalRenderFrameProtocolError.invalidCompletionFence
        }
        self.eventID = eventID
        self.value = value
    }
}
