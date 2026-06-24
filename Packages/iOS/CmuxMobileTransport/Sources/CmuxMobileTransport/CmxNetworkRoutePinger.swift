public import CMUXMobileCore
import Foundation

/// The production ``CmxRoutePinging``: opens (and immediately closes) a real TCP
/// connection over ``CmxNetworkByteTransport`` and times the connect.
public struct CmxNetworkRoutePinger: CmxRoutePinging {
    /// Creates a pinger that dials real TCP connections via ``CmxNetworkByteTransport``.
    public init() {}

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
