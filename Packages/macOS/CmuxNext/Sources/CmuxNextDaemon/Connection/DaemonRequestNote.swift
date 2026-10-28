import CmuxNextCompat
import CmuxNextMetrics
import Foundation

/// The last request the app sent one daemon, on any of its connections to it: the control connection and every
/// terminal view's own (``DaemonEndpoint/requests``). A daemon that stops answering is counted by the class of
/// this request (`daemon.unresponsive`, p09-observability-109): what it was asked before it stalled, most often a
/// person's key (`terminal_io`).
///
/// Each transport notes a request when its line or frame is written (``LineTransport/submit(_:deadline:framed:notes:_:)``),
/// except the heartbeat's own liveness ask. One relaxed store per request.
final class DaemonRequestNote: Sendable {
    /// The method id of the last request plus one; 0 before one.
    private let last = Atomic<UInt64>(0)

    init() {}

    /// A request of method `id` (``DaemonCommandName/id``) went out.
    func sent(_ id: UInt16) {
        last.store(UInt64(truncatingIfNeeded: id) &+ 1, ordering: .relaxed)
    }

    /// A request whose wire `cmd` is `wire` went out (``DaemonCommandName/lookup(_:)``: one hash, no allocation).
    func sent(wire: String) {
        sent(DaemonCommandName.lookup(wire))
    }

    /// The daemon's class of the last request; nil before one.
    var lastClass: HistogramID.MethodClass? {
        let stored = last.load(ordering: .relaxed)
        guard stored > 0 else { return nil }
        let position = DaemonCommandName.methodClassPosition(id: UInt16(truncatingIfNeeded: stored &- 1))
        return HistogramID.MethodClass.allCases.dropFirst(position).first ?? .other
    }
}
