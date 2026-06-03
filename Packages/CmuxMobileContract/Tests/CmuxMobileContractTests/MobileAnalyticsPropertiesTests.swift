import Foundation
import Testing
@testable import CmuxMobileContract

@Suite struct MobileAnalyticsPropertiesTests {
    @Test func withDefaultsFillsMissingPlatformAndBundle() {
        let props = MobileAnalyticsProperties(teamId: "team")
        let defaulted = props.withDefaults(platform: "ios", bundleId: "dev.cmux.app")
        #expect(defaulted.platform == "ios")
        #expect(defaulted.bundleId == "dev.cmux.app")
        #expect(defaulted.teamId == "team")
    }

    @Test func withDefaultsKeepsExistingValues() {
        let props = MobileAnalyticsProperties(platform: "watchos", bundleId: "set")
        let defaulted = props.withDefaults(platform: "ios", bundleId: "dev.cmux.app")
        #expect(defaulted.platform == "watchos")
        #expect(defaulted.bundleId == "set")
    }

    @Test func encodesEventNameRawValue() throws {
        let data = try JSONEncoder().encode(MobileAnalyticsEventName.mobileWorkspaceOpened)
        let string = String(data: data, encoding: .utf8)
        #expect(string == "\"mobile_workspace_opened\"")
    }
}
