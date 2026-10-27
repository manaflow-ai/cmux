import CmuxNextHangReports
import CmuxNextTrace
import Testing

/// A report's launch temperature is the launch's one classification (``LaunchClock/Temperature``, task 034) under
/// the same name, undetermined included.
struct LaunchTemperatureMappingTests {
    @Test(arguments: LaunchClock.Temperature.allCases)
    func reportValueIsTheClassifiersName(temperature: LaunchClock.Temperature) {
        #expect(LaunchTemperature(temperature).rawValue == temperature.name)
    }

    @Test func everyReportValueHasAClassification() {
        #expect(Set(LaunchClock.Temperature.allCases.map { LaunchTemperature($0) }) == Set(LaunchTemperature.allCases))
    }
}
