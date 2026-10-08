import Foundation

/// One rb/1 popup surface's display stream as a `RemoteViewStreamSource`,
/// so a surface decodes and presents through the same pipeline as the page.
/// Session status and the cursor belong to the page's source.
nonisolated final class RemoteRdSurfaceStreamSource: RemoteViewStreamSource {
    private let transport: RemoteRdStreamTransport
    private let stream: UInt16

    init(transport: RemoteRdStreamTransport, stream: UInt16) {
        self.transport = transport
        self.stream = stream
    }

    func accessUnits() -> AsyncStream<RemoteAccessUnit> {
        transport.surfaceAccessUnits(stream: stream)
    }

    func statusUpdates() -> AsyncStream<RemoteViewStatus> {
        AsyncStream { $0.finish() }
    }

    func cursorUpdates() -> AsyncStream<RemoteCursorState> {
        AsyncStream { $0.finish() }
    }

    func requestKeyframe() {
        transport.requestKeyframe(stream: stream)
    }
}
