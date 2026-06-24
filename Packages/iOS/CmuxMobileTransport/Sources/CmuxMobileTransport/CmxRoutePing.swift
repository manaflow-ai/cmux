public import CMUXMobileCore
import Foundation

/// The outcome of a single reachability probe (``CmxRoutePinging/ping(_:timeoutNanoseconds:)``)
/// against one route's address. This is a pure TCP connect: it proves whether the
/// phone can open a socket to the Mac's host/port right now, independent of the
/// live event-stream/RPC subscription. That distinction is the whole point of the
/// Computers screen's ping: a workspace can show "Disconnected" (the live stream
/// dropped) while the Mac is perfectly reachable, and this surfaces that fact.
///
/// Failure kinds mirror ``CmxConnectFailureKind`` so the UI can give the same
/// actionable phrasing pairing already uses (refused = app not running, etc.).
public enum CmxRoutePingResult: Sendable, Equatable {
    /// The TCP connection opened; the Mac is reachable. Carries the round-trip
    /// connect latency in whole milliseconds.
    case reachable(latencyMilliseconds: Int)
    /// The address answered with a refusal: the host is up but nothing is
    /// listening on the port (cmux not running, or mobile pairing off).
    case refused
    /// No route to the host: off Tailscale, asleep, or on another network.
    case unreachable
    /// The connect attempt did not complete before the timeout.
    case timedOut
    /// DNS resolution of the host failed.
    case dnsFailed
    /// The OS blocked the connection (iOS Local Network privacy).
    case permissionDenied
    /// Any other failure; carries a short description for display/logging.
    case failed(description: String)
    /// The route carries no host/port endpoint this probe can dial.
    case unsupportedRoute
}

extension CmxRoutePingResult {
    /// Whether the probe proved the Mac's address is reachable at the TCP layer.
    public var isReachable: Bool {
        if case .reachable = self { return true }
        return false
    }
}

/// Probes whether the phone can reach a Mac route right now. Injected into the
/// Computers screen as a seam so the UI depends on this protocol, not a concrete
/// network call, and tests can substitute a fake instead of opening real
/// sockets.
public protocol CmxRoutePinging: Sendable {
    /// Probe one route, returning the connect latency or a classified failure.
    /// Never throws: every outcome is folded into a ``CmxRoutePingResult``.
    /// - Parameters:
    ///   - route: The route to probe. Non-host/port routes return
    ///     ``CmxRoutePingResult/unsupportedRoute``.
    ///   - timeoutNanoseconds: Connect deadline.
    func ping(_ route: CmxAttachRoute, timeoutNanoseconds: UInt64) async -> CmxRoutePingResult
}

extension CmxRoutePinging {
    /// Probe with the default 5s deadline so a dead route resolves quickly
    /// instead of hanging the Ping button.
    public func ping(_ route: CmxAttachRoute) async -> CmxRoutePingResult {
        await ping(route, timeoutNanoseconds: 5 * 1_000_000_000)
    }
}

/// The production ``CmxRoutePinging``: opens (and immediately closes) a real TCP
/// connection over ``CmxNetworkByteTransport`` and times the connect.
public struct CmxNetworkRoutePinger: CmxRoutePinging {
    public init() {}

    public func ping(
        _ route: CmxAttachRoute,
        timeoutNanoseconds: UInt64 = 5 * 1_000_000_000
    ) async -> CmxRoutePingResult {
        let transport: CmxNetworkByteTransport
        do {
            transport = try CmxNetworkByteTransport(
                route: route,
                connectTimeoutNanoseconds: timeoutNanoseconds
            )
        } catch {
            // Empty host, bad port, or a non-host/port endpoint: nothing to dial.
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
            return CmxRoutePingResult(transportError: error)
        } catch {
            await transport.close()
            return .failed(description: String(describing: error))
        }
    }
}

extension CmxRoutePingResult {
    /// Fold a transport error into a ping result, reusing the transport's own
    /// ``CmxConnectFailureKind`` classification.
    init(transportError error: CmxNetworkByteTransportError) {
        switch error {
        case .connectionTimedOut:
            self = .timedOut
        case let .connectionFailed(description, kind):
            switch kind {
            case .connectionRefused:
                self = .refused
            case .hostUnreachable:
                self = .unreachable
            case .timedOut:
                self = .timedOut
            case .dnsFailed:
                self = .dnsFailed
            case .permissionDenied:
                self = .permissionDenied
            case .secureChannelFailed, .generic:
                self = .failed(description: description)
            }
        case .emptyHost, .invalidPort, .invalidMaximumReceiveLength,
             .unsupportedRouteKind, .unsupportedEndpoint:
            self = .unsupportedRoute
        case .notConnected, .alreadyClosed, .receiveAlreadyInProgress,
             .sendAlreadyInProgress, .receiveFailed, .sendFailed:
            self = .failed(description: String(describing: error))
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
