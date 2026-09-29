public import CmuxNextSettings
import Foundation
import Synchronization

/// The app's event log for `events.stream` (the old app's `cmux-events`
/// protocol, v1): numbered events retained in memory (bounded), replayed
/// after a cursor, then streamed live. Launch tooling waits on it, e.g. the
/// iOS dogfood launcher's `mobile.rpc.ready`.
///
/// Bounded (architecture.md 5a): `retainLimit` events kept for replay;
/// each subscriber buffers at most `subscriberBuffer` events and drops the
/// oldest beyond that.
public final class ControlEventBus: Sendable {
    public static let protocolName = "cmux-events"
    public static let protocolVersion = 1
    public static let heartbeatIntervalSeconds = 15

    public let bootID = UUID().uuidString.lowercased()
    let retainLimit: Int
    let subscriberBuffer: Int
    private let state = Mutex(State())

    struct State {
        var nextSequence: Int64 = 1
        var retained: [JSONValue] = []
        var subscribers: [UUID: Subscriber] = [:]
    }

    struct Subscriber {
        var names: Set<String>
        var categories: Set<String>
        var continuation: AsyncStream<JSONValue>.Continuation
    }

    /// One subscription: the ack frame, retained events after the cursor,
    /// then live events until `cancel()`.
    public struct Subscription: Sendable {
        public let ack: JSONValue
        public let replay: [JSONValue]
        public let events: AsyncStream<JSONValue>
        let bus: ControlEventBus
        let id: UUID

        public func cancel() { bus.unsubscribe(id) }
    }

    public init(retainLimit: Int = 512, subscriberBuffer: Int = 256) {
        self.retainLimit = retainLimit
        self.subscriberBuffer = subscriberBuffer
    }

    public var latestSequence: Int64 { state.withLock { $0.nextSequence - 1 } }

    /// Appends one event and delivers it to matching subscribers.
    @discardableResult
    public func publish(name: String, category: String, source: String, payload: [String: JSONValue]) -> Int64 {
        state.withLock { state in
            let sequence = state.nextSequence
            state.nextSequence += 1
            let event: JSONValue = .object([
                "type": "event", "protocol": .string(Self.protocolName), "version": JSONValue(Self.protocolVersion),
                "boot_id": .string(bootID), "seq": JSONValue(Int(sequence)), "id": .string("\(bootID)-\(sequence)"),
                "name": .string(name), "category": .string(category), "source": .string(source),
                "occurred_at": .string(Self.timestamp()), "workspace_id": .null, "surface_id": .null, "pane_id": .null,
                "window_id": .null, "payload": .object(payload),
            ])
            state.retained.append(event)
            if state.retained.count > retainLimit { state.retained.removeFirst(state.retained.count - retainLimit) }
            for subscriber in state.subscribers.values where Self.matches(event, subscriber.names, subscriber.categories) {
                subscriber.continuation.yield(event)
            }
            return sequence
        }
    }

    /// Subscribes to events after `afterSequence` (nil: live only).
    public func subscribe(after afterSequence: Int64?, names: Set<String>, categories: Set<String>) -> Subscription {
        let (stream, continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .bufferingNewest(subscriberBuffer))
        let id = UUID()
        let (ack, replay) = state.withLock { state -> (JSONValue, [JSONValue]) in
            let latest = state.nextSequence - 1
            let oldest = state.retained.first?["seq"]?.intValue.map(Int64.init) ?? state.nextSequence
            let after = afterSequence ?? latest
            let replay = state.retained.filter { event in
                (event["seq"]?.intValue.map(Int64.init) ?? 0) > after && Self.matches(event, names, categories)
            }
            var gap: String?
            if let afterSequence, !state.retained.isEmpty, afterSequence < oldest - 1 { gap = "requested sequence is older than the retained event log" }
            if let afterSequence, afterSequence > latest { gap = "requested sequence is newer than this cmux process; cmux probably restarted" }
            state.subscribers[id] = Subscriber(names: names, categories: categories, continuation: continuation)
            var resume: [String: JSONValue] = [
                "after_seq": afterSequence.map { JSONValue(Int($0)) } ?? .null, "requested_after_seq": JSONValue(Int(after)),
                "oldest_seq": JSONValue(Int(oldest)), "latest_seq": JSONValue(Int(latest)), "next_seq": JSONValue(Int(latest + 1)),
                "gap": .bool(gap != nil), "restore_gap": false,
            ]
            if let gap { resume["gap_reason"] = .string(gap) }
            let ack: JSONValue = .object([
                "type": "ack", "protocol": .string(Self.protocolName), "version": JSONValue(Self.protocolVersion),
                "boot_id": .string(bootID), "subscription_id": .string(id.uuidString),
                "heartbeat_interval_seconds": JSONValue(Self.heartbeatIntervalSeconds), "replay_count": JSONValue(replay.count),
                "resume": .object(resume),
                "filters": ["names": .array(names.sorted().map(JSONValue.string)), "categories": .array(categories.sorted().map(JSONValue.string))],
            ])
            return (ack, replay)
        }
        continuation.onTermination = { [weak self] _ in self?.unsubscribe(id) }
        return Subscription(ack: ack, replay: replay, events: stream, bus: self, id: id)
    }

    func heartbeat(subscription: Subscription) -> JSONValue {
        .object([
            "type": "heartbeat", "protocol": .string(Self.protocolName), "version": JSONValue(Self.protocolVersion),
            "boot_id": .string(bootID), "subscription_id": .string(subscription.id.uuidString),
            "latest_seq": JSONValue(Int(latestSequence)), "occurred_at": .string(Self.timestamp()),
        ])
    }

    func unsubscribe(_ id: UUID) {
        let subscriber = state.withLock { $0.subscribers.removeValue(forKey: id) }
        subscriber?.continuation.finish()
    }

    static func matches(_ event: JSONValue, _ names: Set<String>, _ categories: Set<String>) -> Bool {
        if !names.isEmpty, !names.contains(event["name"]?.stringValue ?? "") { return false }
        if !categories.isEmpty, !categories.contains(event["category"]?.stringValue ?? "") { return false }
        return true
    }

    static func timestamp() -> String {
        Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
    }
}
