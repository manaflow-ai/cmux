import CMUXMobileCore
import Foundation

/// Picks which of a device's attach routes this Mac dials, in the host's
/// priority order, together with the authorization the transport needs.
///
/// The trust rule is explicit: discovery (the registry, presence) proposes
/// routes but never authorizes one. A Stack bearer token leaves this Mac over a
/// Tailscale peer address only with the device-bound grant the pairing store
/// recorded when the person paired that Mac, checked against the exact peer
/// address and device id (``CmxLegacyTailscaleAuthorizationEvidence``). Loopback
/// is an explicit test-rig opt-in: another Mac's advertised 127.0.0.1 endpoint
/// would dial this Mac instead. When the account-scoped Iroh client is present,
/// its peer-bound transport is preferred and verifies the broker/device-list
/// tuple before sending application data. WebSocket routes remain unsupported.
struct DeviceRouteSelector: Sendable {
    struct Selection: Equatable, Sendable {
        let route: CmxAttachRoute
        /// The device-bound Tailscale grant; nil only for DEBUG loopback.
        let evidence: CmxLegacyTailscaleAuthorizationEvidence?
    }

    enum SelectionError: Error, Equatable, Sendable {
        case noRoutes
        /// Tailscale peer routes exist, but the pairing store holds no grant for any of them.
        case needsAuthorization
        case noDialableRoute(kinds: [String])
    }

    let allowsDebugLoopback: Bool
    let allowsIroh: Bool

    init(allowsDebugLoopback: Bool = false, allowsIroh: Bool = false) {
        self.allowsDebugLoopback = allowsDebugLoopback
        self.allowsIroh = allowsIroh
    }

    var supportedKinds: [CmxAttachTransportKind] {
        (allowsIroh ? [.iroh] : []) + (allowsDebugLoopback ? [.tailscale, .debugLoopback] : [.tailscale])
    }

    /// Routes in dial order: the host's priority (lowest first), ties by id.
    static func ordered(_ routes: [CmxAttachRoute]) -> [CmxAttachRoute] {
        routes.sorted { left, right in
            left.priority != right.priority ? left.priority < right.priority : left.id < right.id
        }
    }

    /// The best dialable route with its authorization. `grant` is the pairing
    /// store's answer for one route; a grant that names another device or
    /// another peer never authorizes the dial.
    func select(
        from routes: [CmxAttachRoute],
        instance: SurfaceDeviceInstanceID,
        grant: (CmxAttachRoute) -> CmxLegacyTailscaleAuthorizationEvidence?
    ) throws -> Selection {
        guard !routes.isEmpty else { throw SelectionError.noRoutes }
        let ordered = Self.ordered(routes)
        if allowsIroh, let route = ordered.first(where: {
            guard $0.kind == .iroh, case .peer = $0.endpoint else { return false }
            return (try? $0.validate()) != nil
        }) {
            return Selection(route: route, evidence: nil)
        }
        var sawTailscalePeer = false
        for route in ordered {
            switch (route.kind, route.endpoint) {
            case (.tailscale, .hostPort(let host, let port)):
                guard CmxTailscalePeerAddress(host) != nil else { continue }
                sawTailscalePeer = true
                guard let evidence = grant(route),
                      evidence.authorizes(macDeviceID: instance.deviceID, host: host, port: port) else { continue }
                return Selection(route: route, evidence: evidence)
            case (.debugLoopback, .hostPort):
                guard allowsDebugLoopback, CmxLoopbackHost().matches(route.endpoint) else { continue }
                return Selection(route: route, evidence: nil)
            default:
                continue
            }
        }
        if sawTailscalePeer { throw SelectionError.needsAuthorization }
        throw SelectionError.noDialableRoute(kinds: ordered.map { $0.kind.rawValue })
    }
}
