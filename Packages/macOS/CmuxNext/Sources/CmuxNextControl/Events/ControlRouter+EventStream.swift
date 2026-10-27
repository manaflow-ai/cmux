public import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// `events.stream`: the one streaming method. The connection writes an
/// ack frame, the replay after `after_seq`, then live events and
/// heartbeats until the client hangs up. The client's reading side (the
/// `cmux events` CLI) closes the socket when it has what it needs.
extension ControlRouter {
    public static let eventStreamMethod = "events.stream"

    /// Streams `request`'s events through `emit` until `hangup` returns.
    public func streamEvents(_ request: ControlRequest, emit: @escaping @Sendable (String) -> Void,
                             hangup: @escaping @Sendable () async -> Void,
                             clock: any Clock<Duration> = ContinuousClock()) async {
        let params = request.params
        let after = params["after_seq"]?.intValue.map(Int64.init)
        let names = Set(params["names"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let categories = Set(params["categories"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let heartbeats = params["include_heartbeats"]?.boolValue ?? true
        let subscription = events.subscribe(after: after, names: names, categories: categories)
        defer { subscription.cancel() }
        emit(subscription.ack.compactText)
        for event in subscription.replay { emit(event.compactText) }
        let bus = events
        let keepalive: EventStreamKeepalive? = heartbeats
            ? EventStreamKeepalive(clock: clock, beat: { emit(bus.heartbeat(subscription: subscription).compactText) })
            : nil
        keepalive?.wrote()
        // concurrency-allow: the live events and the hangup race; every child ends on cancellation
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in subscription.events {
                    keepalive?.wrote()
                    emit(event.compactText)
                }
            }
            group.addTask { await hangup() }
            _ = await group.next()
            group.cancelAll()
        }
        keepalive?.stop()
    }
}

/// `events.stream`'s heartbeat (`include_heartbeats`, on by default): one line after
/// ``ControlEventBus/heartbeatIntervalSeconds`` of silence, so a client can tell a quiet stream from a dead
/// one. A one-shot ``DemandTimer`` that every written line moves on, as a keepalive that traffic resets
/// (Chromium's `base::RetainingOneShotTimer::Reset()`, base/timer/timer.h): a stream with events writes no
/// heartbeat, and a silent one wakes once per interval while its client stays connected.
private final class EventStreamKeepalive: Sendable {
    private let timer: DemandTimer
    private let interval = Duration.seconds(ControlEventBus.heartbeatIntervalSeconds)
    private let beat: @Sendable () -> Void

    init(clock: any Clock<Duration>, beat: @escaping @Sendable () -> Void) {
        timer = DemandTimer(owner: "ControlEventBus.heartbeat", clock: clock)
        self.beat = beat
    }

    /// The stream is about to write a line: the heartbeat moves to a whole interval from now.
    func wrote() {
        timer.schedule(after: interval) { [weak self] in self?.fire() }
    }

    /// The client hung up.
    func stop() { timer.cancel() }

    private func fire() {
        wrote()
        beat()
    }
}
