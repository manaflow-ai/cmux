internal import Foundation

extension ControlCommandCoordinator {
    /// Handles the opt-in aggregate performance counter surface in optimized
    /// builds. The context owns collection and redaction; this package only
    /// routes typed JSON values.
    func handlePerformance(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "performance.metrics.read":
            return performanceMetricsResult(context?.controlPerformanceMetricsRead())
        case "performance.metrics.reset":
            return performanceMetricsResult(context?.controlPerformanceMetricsReset())
        case "performance.metrics.stop":
            return performanceMetricsResult(context?.controlPerformanceMetricsStop())
        default:
            return nil
        }
    }

    private func performanceMetricsResult(_ payload: JSONValue?) -> ControlCallResult {
        guard let payload else {
            return .err(
                code: "unavailable",
                message: "Performance metrics unavailable",
                data: nil
            )
        }
        return .ok(payload)
    }
}
