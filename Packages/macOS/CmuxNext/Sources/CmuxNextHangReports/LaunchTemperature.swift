/// How much of cmux had to come from disk at launch, as a report sends it: Chrome's
/// `StartupTemperature` (`components/startup_metric_utils/common/startup_metric_utils.h`), decided
/// once at the main run loop's start from the page-in count. Built from the launch's one classifier,
/// `LaunchClock.Temperature` (``init(_:)``). Every launch histogram is split by it, as every
/// Chrome `Startup.*` histogram is (its `.ColdStartup`, `.WarmStartup` and `.LukewarmStartup` suffixes).
public nonisolated enum LaunchTemperature: String, Codable, Sendable, CaseIterable {
    /// Most of the binary was paged in from disk (first launch after boot or a purge).
    case cold
    /// Between the cold and warm page-in thresholds.
    case lukewarm
    /// Almost everything was already in memory.
    case warm
    /// The page-in count could not be read.
    case undetermined
}
