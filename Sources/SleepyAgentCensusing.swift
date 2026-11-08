import Foundation

/// Agent census provider. Injected into the renderer (and owned by
/// `SleepyModeController`) so tests/previews can supply deterministic counts
/// instead of reaching a global.
@MainActor
protocol SleepyAgentCensusing: AnyObject {
    /// Returns the current agent counts, sampled at most every couple seconds.
    func sample(at time: Double) -> SleepyAgentCounts
    /// DEBUG-only override so automation can summon pets without live agents.
    var debugOverride: SleepyAgentCounts? { get set }
}
