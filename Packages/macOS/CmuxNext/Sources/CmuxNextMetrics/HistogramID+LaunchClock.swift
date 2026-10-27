public import CmuxNextTrace

extension HistogramID.LaunchTemperature {
    /// The histogram suffix of `temperature`, the launch's one classification (``LaunchClock/Temperature``, decided
    /// once from the page-ins). Nil for an undetermined launch: Chrome records no temperature-split sample for one.
    public init?(_ temperature: LaunchClock.Temperature) {
        switch temperature {
        case .warm: self = .warm
        case .lukewarm: self = .lukewarm
        case .cold: self = .cold
        case .undetermined: return nil
        }
    }
}
