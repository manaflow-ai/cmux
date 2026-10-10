#if DEBUG
import CmuxNextRemoteView
import Foundation
import Synchronization

/// Development builds only (cx-wb5.75): the stream source, input sink and
/// upstream control of a real rd desktop session, over a transport that is
/// replaced for each connection. A `RemoteRdStreamTransport` serves one
/// session: after Stop, a hidden tab or a host end it cannot connect again,
/// so Reconnect and a resumed tab get a new one (`replace`). The pane keeps
/// this one object as its source and re-subscribes when it starts again.
nonisolated final class RemoteRdDebugSource: RemoteViewStreamSource, RemoteUpstreamControl {
    private let current: Mutex<RemoteRdStreamTransport>

    init(_ transport: RemoteRdStreamTransport) {
        current = Mutex(transport)
    }

    var transport: RemoteRdStreamTransport { current.withLock { $0 } }

    /// Ends the current transport's session and uses `next` from now on.
    func replace(with next: RemoteRdStreamTransport) {
        let old = current.withLock { current in
            defer { current = next }
            return current
        }
        old.stop()
    }

    func accessUnits() -> AsyncStream<RemoteAccessUnit> { transport.accessUnits() }

    /// The transport's statuses. On the first `streaming` status it asks the
    /// host for a keyframe: the pane subscribes to access units from a task,
    /// so the session's first IDR can arrive before the subscription.
    func statusUpdates() -> AsyncStream<RemoteViewStatus> {
        let transport = self.transport
        let upstream = transport.statusUpdates()
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteViewStatus.self, bufferingPolicy: .bufferingNewest(4))
        let task = Task {
            var askedKeyframe = false
            for await status in upstream {
                if !askedKeyframe, status.state == .streaming {
                    askedKeyframe = true
                    transport.requestKeyframe()
                }
                continuation.yield(status)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func cursorUpdates() -> AsyncStream<RemoteCursorState> { transport.cursorUpdates() }
    func requestKeyframe() { transport.requestKeyframe() }
    func requestUpstream(_ kind: RemoteUpstreamKind, permissionGranted: Bool) {
        transport.requestUpstream(kind, permissionGranted: permissionGranted)
    }
    func stopUpstream(_ kind: RemoteUpstreamKind) { transport.stopUpstream(kind) }
    func stopAllUpstreams() { transport.stopAllUpstreams() }
}

/// The pane's input, sent on the debug source's current transport.
final class RemoteRdDebugInputSink: RemoteViewInputSink {
    private let source: RemoteRdDebugSource

    init(source: RemoteRdDebugSource) {
        self.source = source
    }

    func send(_ event: RemoteInputEvent) { source.transport.send(event) }
}
#endif
