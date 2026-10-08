public import CmuxLink
public import CmuxLinkDirect
import os

/// Which carriers one Mac's session may race right now (b4-direct.md
/// section 5): B4's `DirectRoutePlanner` over the Mac's direct endpoints,
/// the latest path snapshot, and whether the last direct connect failed
/// although its route was up. A `PathSelector` is fixed per session, so the
/// plan gates carriers at connect time instead of rebuilding the selector.
public final class MobileCarrierPlan: DirectRouteProvider, DirectEndpointResolver, Sendable {
    struct State: Sendable {
        var endpoints: [DirectEndpoint]
        var snapshot: DirectPathSnapshot?
        var directFailed = false
    }

    private let planner = DirectRoutePlanner()
    private let transport: MobileTransportPreference
    // carve-out: read synchronously from every carrier's connect.
    private let state: OSAllocatedUnfairLock<State>

    public init(endpoints: [DirectEndpoint], snapshot: DirectPathSnapshot?,
                transport: MobileTransportPreference = .automatic) {
        self.transport = transport
        state = OSAllocatedUnfairLock(initialState: State(endpoints: endpoints, snapshot: snapshot))
    }

    public var currentSnapshot: DirectPathSnapshot? { state.withLock { $0.snapshot } }
    public var endpoints: [DirectEndpoint] { state.withLock { $0.endpoints } }
    public var directFailed: Bool { state.withLock { $0.directFailed } }

    public func endpoints(for peer: LinkPeer) async -> [DirectEndpoint] { endpoints }

    /// Whether a carrier of `kind` takes part in the next race.
    public func admits(_ kind: CarrierKind) -> Bool {
        switch transport {
        case .direct:
            return kind == .direct
        case .webrtc:
            return kind == .webrtc || kind == .webrtcWireGuard
        case .automatic:
            break
        }
        let current = state.withLock { $0 }
        let direct = PlanMarker(kind: .direct)
        let other = PlanMarker(kind: .webrtc)
        let planned = planner.carriers(direct: direct, endpoints: current.endpoints, snapshot: current.snapshot,
                                       others: [other], directFailed: current.directFailed)
        let isDirect = kind == .direct
        return planned.contains { ($0.kind == .direct) == isDirect }
    }

    /// A new path snapshot: direct gets a fresh chance.
    public func update(snapshot: DirectPathSnapshot) {
        state.withLock {
            $0.snapshot = snapshot
            $0.directFailed = false
        }
    }

    public func update(endpoints: [DirectEndpoint]) {
        state.withLock {
            if $0.endpoints != endpoints { $0.directFailed = false }
            $0.endpoints = endpoints
        }
    }

    func recordDirect(succeeded: Bool) {
        state.withLock { $0.directFailed = !succeeded }
    }
}

/// Stands in for a carrier when asking the planner.
private struct PlanMarker: LinkCarrier {
    let kind: CarrierKind
    var candidatePaths: [PathKind] { [] }
    func connect(to peer: LinkPeer) async throws -> any LinkTransport { throw CancellationError() }
}
