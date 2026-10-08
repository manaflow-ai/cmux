public import Foundation

/// A bidirectional channel of one link. `events` has a single consumer;
/// taking a reliable message from it is what acknowledges it to the sender,
/// so a slow consumer back-pressures the remote `send`.
public final class LinkChannel: Sendable, Identifiable {
    public let id: UInt32
    public let descriptor: ChannelDescriptor
    let incarnation: UInt64
    private let session: LinkSession

    init(id: UInt32, incarnation: UInt64, descriptor: ChannelDescriptor, session: LinkSession) {
        self.id = id
        self.incarnation = incarnation
        self.descriptor = descriptor
        self.session = session
    }

    public var stream: String { descriptor.stream }

    /// Inbound events in order. Iterate from one task only.
    public var events: ChannelEvents { ChannelEvents(session: session, channel: id, incarnation: incarnation) }

    /// Sends one message and returns its revision. Reliable channels suspend
    /// while the unacknowledged bytes would exceed the budget; other classes
    /// drop their oldest queued message instead.
    @discardableResult
    public func send(_ payload: Data) async throws -> UInt64 {
        try await session.channelSend(id, incarnation, payload)
    }

    /// Waits until the peer consumed every reliable message sent so far.
    public func flush() async throws {
        try await session.channelFlush(id, incarnation)
    }

    /// Sets the priority and optional directional budget of this side's sends
    /// only; the peer's direction keeps the declared values. Call before
    /// sending: frames already queued keep the priority they were queued at.
    public func setSendPriority(_ priority: ChannelPriority, budgetBytes: Int? = nil) async {
        await session.channelSetSendPriority(id, incarnation, priority, budgetBytes: budgetBytes)
    }

    /// The inbound cursor to save for `openChannel(_:resumeFrom:)`.
    public func cursor() async -> StreamCursor {
        await session.channelCursor(id, incarnation, stream: descriptor.stream)
    }

    /// Closes both directions. The peer delivers what it received, then
    /// `.closed(.remote)`. Call `flush()` first to guarantee delivery.
    public func close() async {
        await session.channelClose(id, incarnation)
    }
}
