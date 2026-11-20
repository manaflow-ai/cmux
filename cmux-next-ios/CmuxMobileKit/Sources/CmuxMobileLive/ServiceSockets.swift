import Foundation

/// What happened to one socket of a cmux service surface (Mac presence, a Cloud Chief conversation,
/// the device hub), as ``ConnectivityIncidentReporter/serviceSocket(_:id:_:)`` takes it.
public enum ServiceSocketEvent: Sendable, Equatable {
    /// A dial started.
    case dialing
    /// The socket is live.
    case connected
    /// A dial failed or the live socket ended, and why. A drop when it was the last live socket.
    case failed(reason: String)
    /// The feature replaced its socket on purpose (a foreground, a network change, a restart of the
    /// hub): still wanted, not live, and no drop.
    case restarting
    /// The socket is no longer wanted (its feature stopped, or the service refused it for good).
    /// Final: whatever arrives for this socket id afterwards is ignored, so a late `connected` from a
    /// socket closed mid-welcome can never leave the service looking live.
    case closed
}

/// What several sockets of one service surface mean together (each open Cloud Chief conversation
/// keeps its own socket): the service is reachable while any socket is live, trying while none is
/// live and one is wanted, and not wanted once none is. Pure; ``ConnectivityIncidentReporter`` runs it.
struct ServiceSockets: Sendable, Equatable {
    enum Socket: Sendable, Equatable {
        case trying(reason: String?)
        case connected
    }

    /// What one socket event did to the surface.
    struct Change: Sendable, Equatable {
        /// The surface's state now.
        var state: ConnectivityIncidentDetector.LinkState
        /// The surface went from live to not live because a live socket failed (a drop).
        var droppedReason: String?
        /// Whether the detector needs to hear it (the state changed, a new dial started, or a drop).
        var changed: Bool
    }

    private var sockets: [String: Socket] = [:]
    /// Sockets that closed: their later events are stale.
    private var closed: Set<String> = []
    private var last: ConnectivityIncidentDetector.LinkState = .notWanted(.linkClosed)

    static let transport = "websocket"

    mutating func apply(_ id: String, _ event: ServiceSocketEvent) -> Change {
        guard !closed.contains(id) else { return Change(state: last, droppedReason: nil, changed: false) }
        let wasLive = sockets.values.contains(.connected)
        var newDial = false
        var failure: String?
        switch event {
        case .dialing:
            newDial = true
            if case .trying = sockets[id] {} else { sockets[id] = .trying(reason: nil) }
        case .connected:
            sockets[id] = .connected
        case .failed(let reason):
            failure = reason
            sockets[id] = .trying(reason: reason)
        case .restarting:
            if case .trying = sockets[id] {} else { sockets[id] = .trying(reason: nil) }
        case .closed:
            sockets[id] = nil
            closed.insert(id)
        }
        let state = aggregate(newDial: newDial)
        let isLive = sockets.values.contains(.connected)
        let dropped = wasLive && !isLive ? failure : nil
        let changed = state != last || newDial || dropped != nil
        last = state
        return Change(state: state, droppedReason: dropped, changed: changed)
    }

    private func aggregate(newDial: Bool) -> ConnectivityIncidentDetector.LinkState {
        if sockets.values.contains(.connected) { return .connected(transport: Self.transport) }
        var wanted = false
        var reasons: [String] = []
        for case .trying(let reason) in sockets.values {
            wanted = true
            if let reason { reasons.append(reason) }
        }
        guard wanted else { return .notWanted(.linkClosed) }
        return .trying(transport: Self.transport, reason: reasons.sorted().first, newDial: newDial)
    }
}
