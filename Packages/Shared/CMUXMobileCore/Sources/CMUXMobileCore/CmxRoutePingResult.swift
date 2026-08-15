/// The outcome of a single reachability probe (``CmxRoutePinging/ping(_:timeoutNanoseconds:)``)
/// against one route's address. This is a pure TCP connect: it proves whether the
/// phone can open a socket to the Mac's host/port right now, independent of the
/// live event-stream/RPC subscription. That distinction is the whole point of the
/// Computers screen's ping: a workspace can show "Disconnected" (the live stream
/// dropped) while the Mac is perfectly reachable, and this surfaces that fact.
///
/// Lives in the core package (not the transport package) so UI/model code can
/// depend on the result and the ``CmxRoutePinging`` seam without importing the
/// concrete network transport.
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
    /// Both ``reachable`` and ``refused`` qualify: a refusal is an RST from a live
    /// host, which proves the address is reachable even though nothing is
    /// listening on the port. Use ``isListening`` for "the cmux port answered".
    public var isReachable: Bool {
        switch self {
        case .reachable, .refused:
            return true
        case .unreachable, .timedOut, .dnsFailed, .permissionDenied, .failed,
             .unsupportedRoute:
            return false
        }
    }

    /// Whether a service actually accepted the connection on the cmux port (only
    /// ``reachable``), as opposed to the host merely being reachable.
    public var isListening: Bool {
        if case .reachable = self { return true }
        return false
    }
}
