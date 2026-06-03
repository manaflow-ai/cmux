import Testing
@testable import CmuxiOSConfig

@Suite struct UITestConfigMockDataTests {
    @Test func explicitOneEnablesMockData() {
        #expect(UITestConfig.mockDataEnabled(from: ["CMUX_UITEST_MOCK_DATA": "1"]))
    }

    @Test func explicitZeroDisablesEvenUnderXCTest() {
        let env = [
            "CMUX_UITEST_MOCK_DATA": "0",
            "XCTestConfigurationFilePath": "/tmp/run.xctestconfiguration",
        ]
        #expect(UITestConfig.mockDataEnabled(from: env) == false)
    }

    @Test func xctestPresenceEnablesMockData() {
        let env = ["XCTestConfigurationFilePath": "/tmp/run.xctestconfiguration"]
        #expect(UITestConfig.mockDataEnabled(from: env))
    }

    @Test func emptyEnvironmentDisablesMockData() {
        #expect(UITestConfig.mockDataEnabled(from: [:]) == false)
    }
}
