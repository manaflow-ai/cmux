import CmuxNextMetrics
import CmuxNextTrace
import Testing

/// `launch.first_frame.<temperature>` (task 058) takes its suffix from the launch's one classifier,
/// ``LaunchClock/Temperature`` (task 034): the same names, and no histogram for an undetermined launch.
struct LaunchTemperatureHistogramTests {
    @Test(arguments: LaunchClock.Temperature.allCases)
    func suffixIsTheClassifiersName(temperature: LaunchClock.Temperature) {
        let suffix = HistogramID.LaunchTemperature(temperature)
        if temperature == .undetermined {
            #expect(suffix == nil)
        } else {
            #expect(suffix?.rawValue == temperature.name)
        }
    }

    @Test func everySuffixHasAClassification() {
        let mapped = Set(LaunchClock.Temperature.allCases.compactMap { HistogramID.LaunchTemperature($0) })
        #expect(mapped == Set(HistogramID.LaunchTemperature.allCases))
    }
}
