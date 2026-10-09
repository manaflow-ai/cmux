public import CmuxLink
import Network

/// V3: dials a host's direct endpoints over TCP and authenticates with
/// Noise IK pinned to the host key (b4-direct.md). Every transport it makes
/// is on `LinkPath(kind: .direct, carrier: .direct)`.
public final class DirectCarrier: LinkCarrier {
    public let kind = CarrierKind.direct
    public let candidatePaths: [PathKind] = [.direct]

    private let handshake: DirectHandshake
    private let resolver: any DirectEndpointResolver
    private let routes: (any DirectRouteProvider)?
    private let evaluator = DirectRouteEvaluator()
    private let injector: DirectFaultInjector?

    /// - Parameters:
    ///   - identity: this device's static key; the host's trust store must know it.
    ///   - resolver: where endpoints come from (default: `LinkPeer.hints`).
    ///   - routes: the reachability monitor; endpoints whose route cannot
    ///     work are skipped, and with none left `connect` fails at once.
    public convenience init(
        identity: DirectIdentity,
        resolver: any DirectEndpointResolver = DirectHintsResolver(),
        routes: (any DirectRouteProvider)? = nil
    ) {
        self.init(identity: identity, resolver: resolver, routes: routes, faultInjector: nil)
    }

    @_spi(Testing)
    public init(
        identity: DirectIdentity,
        resolver: any DirectEndpointResolver,
        routes: (any DirectRouteProvider)?,
        faultInjector: DirectFaultInjector?
    ) {
        handshake = DirectHandshake(identity: identity)
        self.resolver = resolver
        self.routes = routes
        injector = faultInjector
    }

    public func connect(to peer: LinkPeer) async throws -> any LinkTransport {
        let endpoints = await resolver.endpoints(for: peer)
        guard !endpoints.isEmpty else { throw DirectCarrierError.noEndpoint }
        var usable = endpoints
        if let snapshot = routes?.currentSnapshot {
            let statuses = endpoints.map { evaluator.status(for: $0.target, on: snapshot) }
            usable = zip(endpoints, statuses).filter { $1.isAvailable }.map(\.0)
            if usable.isEmpty, case let .unavailable(blocker)? = statuses.first {
                throw DirectCarrierError.routeUnavailable(blocker)
            }
        }
        var failures: [String] = []
        for endpoint in usable {
            try Task.checkCancellation()
            do {
                return try await dial(endpoint, hostID: peer.hostID)
            } catch DirectCarrierError.handshakeRefused where usable.count == 1 {
                throw DirectCarrierError.handshakeRefused
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(endpoint.target): \(error)")
            }
        }
        try Task.checkCancellation()
        throw DirectCarrierError.allEndpointsFailed(failures)
    }

    private func dial(_ endpoint: DirectEndpoint, hostID: String) async throws -> DirectTransport {
        let socket = DirectSocket(connection: NWConnection(to: endpoint.nwEndpoint, using: DirectSocket.parameters()))
        do {
            try await socket.start()
            let path = LinkPath(kind: injector?.currentPathKind ?? .direct, carrier: .direct)
            return try await withTaskCancellationHandler {
                try await handshake.dial(
                    socket: socket, hostID: hostID, hostKey: endpoint.hostKey, path: path, injector: injector
                )
            } onCancel: {
                socket.cancel()
            }
        } catch {
            socket.cancel()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
