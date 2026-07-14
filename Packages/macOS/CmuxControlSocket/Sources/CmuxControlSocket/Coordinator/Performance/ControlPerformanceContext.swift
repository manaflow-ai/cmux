public import Foundation

/// Release-safe observability seam for opt-in, aggregate performance counters.
/// Payloads contain counts and durations only, never workspace names, paths,
/// command lines, or terminal contents.
@MainActor
public protocol ControlPerformanceContext: AnyObject {
    func controlPerformanceMetricsRead() -> JSONValue?
    func controlPerformanceMetricsReset() -> JSONValue?
    func controlPerformanceMetricsStop() -> JSONValue?
}

public extension ControlPerformanceContext {
    func controlPerformanceMetricsRead() -> JSONValue? { nil }
    func controlPerformanceMetricsReset() -> JSONValue? { nil }
    func controlPerformanceMetricsStop() -> JSONValue? { nil }
}
