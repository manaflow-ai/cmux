public import CmuxLink
public import CmuxLinkWG
public import Foundation

/// One end of an in-memory underlay.
public final class InMemoryUnderlay: DatagramUnderlay {
    public let events: AsyncStream<UnderlayEvent>
    public let maxDatagramBytes: Int
    private let link: InMemoryUnderlayLink
    private let side: InMemoryUnderlayLink.Side

    init(events: AsyncStream<UnderlayEvent>, maxDatagramBytes: Int, link: InMemoryUnderlayLink, side: InMemoryUnderlayLink.Side) {
        self.events = events
        self.maxDatagramBytes = maxDatagramBytes
        self.link = link
        self.side = side
    }

    public var path: PathKind {
        get async { await link.path }
    }

    public func send(_ datagram: Data) async throws {
        try await link.send(datagram, from: side)
    }

    public func close() async {
        await link.close(from: side)
    }

    /// Datagrams this underlay's link carried (both sides).
    public var sentDatagrams: Int {
        get async { await link.sentDatagrams }
    }
}
