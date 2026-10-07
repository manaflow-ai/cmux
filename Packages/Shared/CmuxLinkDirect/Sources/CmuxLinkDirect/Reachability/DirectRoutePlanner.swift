public import CmuxLink

/// Picks the carriers a session races (b4-direct.md section 5): when a
/// direct endpoint is configured and its route can work, only the direct
/// carrier races, so nothing else carries the session; when no direct route
/// can work, the direct carrier is left out.
public struct DirectRoutePlanner: Sendable {
    public var evaluator: DirectRouteEvaluator

    public init(evaluator: DirectRouteEvaluator = DirectRouteEvaluator()) {
        self.evaluator = evaluator
    }

    /// `snapshot == nil` (the monitor has not reported yet) races every
    /// carrier; the path policy still prefers direct. `directFailed` (the
    /// last direct connect failed although the route was up, for example the
    /// host is not listening) also races every carrier, so the session can
    /// fall back while the selector keeps retrying the better direct path.
    public func carriers(
        direct: any LinkCarrier,
        endpoints: [DirectEndpoint],
        snapshot: DirectPathSnapshot?,
        others: [any LinkCarrier],
        directFailed: Bool = false
    ) -> [any LinkCarrier] {
        guard !endpoints.isEmpty else { return others }
        guard let snapshot else { return [direct] + others }
        let reachable = endpoints.contains { evaluator.status(for: $0.target, on: snapshot).isAvailable }
        guard reachable else { return others }
        return directFailed ? [direct] + others : [direct]
    }
}
