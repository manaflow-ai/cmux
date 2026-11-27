public import CMUXMobileCore
import Foundation

/// The production ``CmxRoutePinging``: opens (and immediately closes) a real TCP
/// connection over ``CmxNetworkByteTransport`` and times the connect. Lives in
/// the transport package (the only place that knows the concrete socket layer);
/// the protocol and result type it satisfies live in CMUXMobileCore.
public struct CmxNetworkRoutePinger: CmxRoutePinging {
    private let transportFactory: CmxNetworkByteTransportFactory

    /// Creates a pinger that dials real TCP connections via ``CmxNetworkByteTransport``.
    public init() {
        transportFactory = CmxNetworkByteTransportFactory()
    }

    /// Open a TCP connection to the route's host/port, measure the connect
    /// latency, then close. Returns the latency or a classified failure; never
    /// throws.
    /// - Parameters:
    ///   - route: The route to probe. Non-host/port routes return
    ///     ``CmxRoutePingResult/unsupportedRoute``.
    ///   - timeoutNanoseconds: Connect deadline (default 5s) so a dead route
    ///     resolves quickly instead of hanging the Ping button.
    public func ping(
        _ route: CmxAttachRoute,
        timeoutNanoseconds: UInt64 = 5 * 1_000_000_000
    ) async -> CmxRoutePingResult {
        let transport: any CmxByteTransport
        do {
            let request = CmxByteTransportRequest(
                route: route,
                expectedPeerDeviceID: nil,
                authorizationMode: .stackBearer
            )
            var factory = transportFactory
            factory.connectTimeoutNanoseconds = max(1, timeoutNanoseconds)
            transport = try factory.makeTransport(for: request)
        } catch {
            // Empty host, bad port, unsupported endpoint, or unavailable
            // Raw Tailscale TCP cannot prove peer identity before bearer use.
            return .unsupportedRoute
        }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await transport.connect()
            let elapsed = clock.now - start
            await transport.close()
            return .reachable(latencyMilliseconds: elapsed.cmxWholeMilliseconds)
        } catch let error as CmxNetworkByteTransportError {
            await transport.close()
            return pingResult(for: error)
        } catch {
            await transport.close()
            return .failed(description: String(describing: error))
        }
    }

    /// Fold a transport error into a ping result, reusing the transport's own
    /// ``CmxConnectFailureKind`` classification. A private instance method on the
    /// owning, constructable type (not a global free function) so the core
    /// package stays free of transport types.
    private func pingResult(for error: CmxNetworkByteTransportError) -> CmxRoutePingResult {
        switch error {
        case .connectionTimedOut:
            return .timedOut
        case let .connectionFailed(description, kind):
            return pingResult(for: kind, description: description)
        case .emptyHost, .invalidPort, .invalidMaximumReceiveLength,
             .unsupportedRouteKind, .unsupportedEndpoint,
             .authorizationIntentRequired, .unsupportedAuthorizationMode,
             .tailscaleAuthorizationUnavailable:
            return .unsupportedRoute
        case .notConnected, .alreadyClosed, .receiveAlreadyInProgress,
             .sendAlreadyInProgress, .receiveFailed, .sendFailed:
            return .failed(description: String(describing: error))
        }
    }

    private func pingResult(
        for kind: CmxConnectFailureKind,
        description: String
    ) -> CmxRoutePingResult {
        switch kind {
        case .connectionRefused:
            return .refused
        case .hostUnreachable:
            return .unreachable
        case .timedOut:
            return .timedOut
        case .dnsFailed:
            return .dnsFailed
        case .permissionDenied:
            return .permissionDenied
        case .secureChannelFailed, .generic:
            return .failed(description: description)
        }
    }
}

private extension Duration {
    /// This duration as whole milliseconds, rounded to nearest, clamped at 0.
    var cmxWholeMilliseconds: Int {
        let components = self.components
        let fromSeconds = components.seconds * 1_000
        // attoseconds (1e-18 s) -> milliseconds (1e-3 s): divide by 1e15.
        let fromAttoseconds = components.attoseconds / 1_000_000_000_000_000
        return max(0, Int(fromSeconds + fromAttoseconds))
    }
}
