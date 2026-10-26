import Foundation

// Development builds only: the pane is not exposed in Release until the
// overlay link token authenticates hello claims (RemoteViewAvailability).
#if DEBUG
/// Records input for demos and tests, and moves the mock host's pointer so
/// the picture reacts (pointer moves damage the synthetic desktop). Every
/// event is applied on the host in arrival order, numbered as the viewer
/// numbers what it sends (``RemoteInputLatency/Sequencer``), so the host's
/// frames echo the input they show.
@MainActor
public final class MockRemoteInputSink: RemoteViewInputSink {
    public private(set) var events: [RemoteInputEvent] = []
    private let host: MockRemoteStreamSource?
    private var sequencer = RemoteInputLatency.Sequencer()
    /// Keep at most this many events (a demo can run for a long time).
    public var limit = 512

    public init(host: MockRemoteStreamSource? = nil) {
        self.host = host
    }

    public func send(_ event: RemoteInputEvent) {
        events.append(event)
        if events.count > limit { events.removeFirst(events.count - limit) }
        host?.inputApplied(sequencer.next())
        if case let .pointer(x, y) = event {
            host?.movePointer(to: CGPoint(x: Int(x), y: Int(y)))
        }
    }

    public func removeAll() { events.removeAll() }
}
#endif
