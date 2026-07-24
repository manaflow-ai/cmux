import Foundation

/// Battery + wifi provider. Injected into the renderer (and owned by
/// `SleepyModeController`) so tests/previews can supply deterministic status.
@MainActor
protocol SleepyStatusProviding: AnyObject {
    /// Returns the current battery + Wi-Fi sample (cached for a few seconds).
    func sample(at time: Double) -> SleepyStatusSample
}
