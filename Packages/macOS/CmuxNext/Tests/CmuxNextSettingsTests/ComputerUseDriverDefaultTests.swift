@testable import CmuxNextSettings
import Testing

/// cmux Remote is the default (docs/cmux-remote.md): Computer Use runs the Upstream driver
/// unless the person picks Legacy, and only a driver the person picked is "set", so a build
/// without the helper v2 falls back to Legacy without a note about a choice nobody made.
struct ComputerUseDriverDefaultTests {
    private func computerUse(_ root: JSONValue) -> ComputerUseSettings {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).computerUse
    }

    @Test func theDefaultIsUpstreamAndNotSet() {
        let settings = computerUse(.object([:]))
        #expect(settings.driver == .upstream)
        #expect(!settings.driverIsSet)
    }

    @Test(arguments: [ComputerUseDriver.legacy, .upstream])
    func aDriverInTheFileIsTheChosenOne(_ driver: ComputerUseDriver) {
        let settings = computerUse(.object(["computerUse": .object(["driver": .string(driver.rawValue)])]))
        #expect(settings.driver == driver)
        #expect(settings.driverIsSet)
    }

    @Test func remoteEnabledIsRetired() {
        #expect(SettingsSchema.retiredKeys["remote.enabled"] != nil)
        #expect(!SettingsSchema.all.contains { $0.path == ["remote", "enabled"] })
    }
}
