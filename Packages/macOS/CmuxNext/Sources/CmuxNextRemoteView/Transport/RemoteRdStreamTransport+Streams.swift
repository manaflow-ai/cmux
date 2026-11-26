public import Foundation
import CmuxNextCompat

extension RemoteRdStreamTransport {
    // MARK: RemoteViewStreamSource

    public func accessUnits() -> AsyncStream<RemoteAccessUnit> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteAccessUnit.self, bufferingPolicy: .bufferingNewest(8))
        let previous = state.withLock { state in
            defer { state.units = continuation }
            return state.units
        }
        previous?.finish()
        return stream
    }

    public func statusUpdates() -> AsyncStream<RemoteViewStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteViewStatus.self, bufferingPolicy: .bufferingNewest(4))
        let (previous, current) = state.withLock { state in
            defer { state.statuses = continuation }
            return (state.statuses, state.status)
        }
        previous?.finish()
        continuation.yield(current)
        return stream
    }

    public func cursorUpdates() -> AsyncStream<RemoteCursorState> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteCursorState.self, bufferingPolicy: .bufferingNewest(1))
        let (previous, current) = state.withLock { state in
            defer { state.cursors = continuation }
            return (state.cursors, state.cursorFeed.current)
        }
        previous?.finish()
        // A still cursor sends again only once a second: a new subscriber starts from the last.
        if let current { continuation.yield(current) }
        return stream
    }

    /// The host's once-a-second counters (`stats`: rate, loss, encode time), newest only; the viewer draws them
    /// (D10: an ultra session shows the link it spends).
    public func hostStatsUpdates() -> AsyncStream<RemoteRdHostStats> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteRdHostStats.self, bufferingPolicy: .bufferingNewest(1))
        let previous = state.withLock { state in
            defer { state.hostStats = continuation }
            return state.hostStats
        }
        previous?.finish()
        return stream
    }
}
