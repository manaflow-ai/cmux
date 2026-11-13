import Foundation

/// What several sockets of one service surface mean together (each open Cloud Chief conversation
/// keeps its own socket): the service is reachable while any socket is live, trying while none is
/// live and one is wanted, and not wanted once none is. Pure; ``ConnectivityIncidentReporter`` runs it.
struct ServiceSockets: Sendable, Equatable {
    enum Socket: Sendable, Equatable {
        case trying(reason: String?)
        case connected
    }

    /// What one socket change did to the surface.
    struct Change: Sendable, Equatable {
        /// The surface's state now (sent to the detector when it changed or a new dial started).
        var state: ConnectivityIncidentDetector.LinkState
        /// The surface went from live to not live because a live socket ended (a drop).
        var droppedReason: String?
        /// Whether the detector needs to hear it.
        var changed: Bool
    }

    private var sockets: [String: Socket] = [:]
    private var last: ConnectivityIncidentDetector.LinkState = .notWanted(.linkClosed)

    static let transport = "websocket"

    /// Socket `id` is now `socket` (nil: no longer wanted). `newDial` when a dial just started.
    mutating func set(_ id: String, _ socket: Socket?, newDial: Bool = false, dropReason: String? = nil) -> Change {
        let wasLive = sockets.values.contains(.connected)
        sockets[id] = socket
        let state = aggregate(newDial: newDial)
        let isLive = sockets.values.contains(.connected)
        let dropped = wasLive && !isLive && dropReason != nil ? dropReason : nil
        let changed = state != last || newDial || dropped != nil
        last = state
        return Change(state: state, droppedReason: dropped, changed: changed)
    }

    private func aggregate(newDial: Bool) -> ConnectivityIncidentDetector.LinkState {
        if sockets.values.contains(.connected) { return .connected(transport: Self.transport) }
        let reasons = sockets.values.compactMap { socket -> String?? in
            if case .trying(let reason) = socket { return .some(reason) }
            return nil
        }
        guard !reasons.isEmpty else { return .notWanted(.linkClosed) }
        return .trying(transport: Self.transport, reason: reasons.compactMap { $0 }.sorted().first, newDial: newDial)
    }
}
