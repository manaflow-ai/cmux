public import CmuxNextTrace

extension LaunchTemperature {
    /// The report value of `temperature`, the launch's one classification (``LaunchClock/Temperature``, decided
    /// once from the page-ins).
    public init(_ temperature: LaunchClock.Temperature) {
        switch temperature {
        case .warm: self = .warm
        case .lukewarm: self = .lukewarm
        case .cold: self = .cold
        case .undetermined: self = .undetermined
        }
    }
}
