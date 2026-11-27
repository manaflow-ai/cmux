public import CmuxNextSettings
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
        // concurrency-allow: heartbeat loop, not a deadline race; every child ends on cancellation
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in subscription.events { emit(event.compactText) }
            }
            if heartbeats {
                group.addTask {
                    // wakeup-allow: client-requested keepalive (include_heartbeats, 15 s) only while an events.stream client is connected; ends on hangup
                    while !Task.isCancelled {
                        do { try await clock.sleep(for: .seconds(ControlEventBus.heartbeatIntervalSeconds)) } catch { return } // wakeup-allow: keepalive period above
                        emit(bus.heartbeat(subscription: subscription).compactText)
                    }
                }
            }
            group.addTask { await hangup() }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
