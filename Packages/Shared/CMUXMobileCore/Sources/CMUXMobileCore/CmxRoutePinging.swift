/// Probes whether the phone can reach a Mac route right now. Lives in the core
/// package so UI/model code can depend on this seam (and a fake) without
/// importing the concrete network transport; the production implementation
/// (`CmxNetworkRoutePinger`) lives in the transport package and is injected from
/// the object graph, e.g. through the shell store.
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
