import Testing
@testable import CmuxMobileShell

@Suite struct MobileExperienceProfileTests {
    @Test func parsesMVPConfigurationValue() {
        #expect(MobileExperienceProfile(configurationValue: "mvp") == .mvp)
        #expect(MobileExperienceProfile(configurationValue: "  MVP  ") == .mvp)
    }

    @Test func missingOrUnknownConfigurationUsesFullExperience() {
        #expect(MobileExperienceProfile(configurationValue: nil) == .full)
        #expect(MobileExperienceProfile(configurationValue: "") == .full)
        #expect(MobileExperienceProfile(configurationValue: "beta") == .full)
    }
}
