import CmuxMobileRPC
import Foundation

/// A terminal-scoped event from a device link's host: raw PTY output for a
/// surface, or the host telling us the surface changed (its effective grid
/// rides along so a byte-stream mirror learns of remote resizes without
/// subscribing to render grids).
enum DeviceTerminalEvent: Equatable, Sendable {
    case bytes(sequence: UInt64?, data: Data)
    case updated(columns: Int?, rows: Int?)
    /// The link reconnected; the consumer must re-attach (viewport, replay, cursor).
    case linkReconnected
    /// The link is gone for now (transport lost, device offline, link stopped).
    case linkLost
    /// The bounded event queue overflowed; consult the current link and replay.
    case resyncRequired

    /// Decode a `terminal.bytes` / `terminal.updated` envelope for its surface.
    /// Returns `(surfaceID, event)`; nil for payloads without a surface.
    static func decode(_ envelope: MobileEventEnvelope) -> (surfaceID: UUID, event: DeviceTerminalEvent)? {
        guard let payload = envelope.payloadJSON else { return nil }
        switch envelope.topic {
        case "terminal.bytes":
            guard let event = MobileTerminalBytesEvent.decode(payload),
                  let surfaceID = UUID(uuidString: event.surfaceID) else { return nil }
            return (surfaceID, .bytes(sequence: event.sequence, data: event.bytes))
        case "terminal.updated":
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let raw = object["surface_id"] as? String,
                  let surfaceID = UUID(uuidString: raw) else { return nil }
            return (surfaceID, .updated(
                columns: (object["columns"] as? NSNumber)?.intValue,
                rows: (object["rows"] as? NSNumber)?.intValue
            ))
        default:
            return nil
        }
    }
}

/// Fans one link's terminal events out to the mirror sessions attached to its
/// surfaces. Each session gets its own bounded stream; a session that falls
/// behind drops oldest frames and, on seeing a sequence gap, replays. Main
/// actor only, like the link that owns it.
@MainActor
final class DeviceLinkTerminalEvents {
    private var continuations: [UUID: [UUID: AsyncStream<DeviceTerminalEvent>.Continuation]] = [:]

    func stream(surfaceID: UUID) -> AsyncStream<DeviceTerminalEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            continuations[surfaceID, default: [:]][id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.remove(surfaceID: surfaceID, id: id) }
            }
        }
    }

    var hasSubscribers: Bool { continuations.values.contains { !$0.isEmpty } }

    func send(_ event: DeviceTerminalEvent, surfaceID: UUID) {
        for continuation in continuations[surfaceID]?.values ?? [:].values {
            deliver(event, to: continuation)
        }
    }

    func broadcast(_ event: DeviceTerminalEvent) {
        for surface in continuations.values {
            for continuation in surface.values {
                deliver(event, to: continuation)
            }
        }
    }

    private func deliver(_ event: DeviceTerminalEvent, to continuation: AsyncStream<DeviceTerminalEvent>.Continuation) {
        if case .dropped = continuation.yield(event) {
            // Every overflow appends a fresh recovery marker. If a later byte
            // drops that marker, it appends another, so recovery cannot vanish.
            continuation.yield(.resyncRequired)
        }
    }

    func finishAll() {
        let all = continuations
        continuations = [:]
        for surface in all.values {
            for continuation in surface.values { continuation.finish() }
        }
    }

    private func remove(surfaceID: UUID, id: UUID) {
        continuations[surfaceID]?[id] = nil
        if continuations[surfaceID]?.isEmpty == true {
            continuations[surfaceID] = nil
        }
    }
}
