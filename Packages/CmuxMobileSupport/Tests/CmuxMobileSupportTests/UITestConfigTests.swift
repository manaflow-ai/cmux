import Testing
@testable import CmuxMobileSupport

@Suite struct UITestConfigTests {
    @Test func explicitDisableWinsOverTestHost() {
        let env = [
            "CMUX_UITEST_MOCK_DATA": "0",
            "XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration",
        ]
        #if DEBUG
        #expect(UITestConfig.mockDataEnabled(from: env) == false)
        #else
        #expect(UITestConfig.mockDataEnabled(from: env) == false)
        #endif
    }

    @Test func explicitEnableTurnsOnMockData() {
        let env = ["CMUX_UITEST_MOCK_DATA": "1"]
        #if DEBUG
        #expect(UITestConfig.mockDataEnabled(from: env) == true)
        #else
        #expect(UITestConfig.mockDataEnabled(from: env) == false)
        #endif
    }

    @Test func testHostPresenceEnablesMockDataInDebug() {
        let env = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
        #if DEBUG
        #expect(UITestConfig.mockDataEnabled(from: env) == true)
        #else
        #expect(UITestConfig.mockDataEnabled(from: env) == false)
        #endif
    }

    @Test func emptyEnvironmentDisablesMockData() {
        #expect(UITestConfig.mockDataEnabled(from: [:]) == false)
    }

    @Test func valueReturnsTrimmedNonEmptyWhenMockEnabled() {
        let env = [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_ADD_DEVICE_NAME": "  Work Mac  ",
        ]
        #if DEBUG
        #expect(UITestConfig.value(for: "CMUX_UITEST_ADD_DEVICE_NAME", env: env) == "Work Mac")
        #else
        #expect(UITestConfig.value(for: "CMUX_UITEST_ADD_DEVICE_NAME", env: env) == nil)
        #endif
    }

    @Test func valueIsNilWhenMockDisabled() {
        let env = ["CMUX_UITEST_ADD_DEVICE_NAME": "Work Mac"]
        #expect(UITestConfig.value(for: "CMUX_UITEST_ADD_DEVICE_NAME", env: env) == nil)
    }

    @Test func valueIsNilWhenBlank() {
        let env = [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_ADD_DEVICE_HOST": "   ",
        ]
        #expect(UITestConfig.value(for: "CMUX_UITEST_ADD_DEVICE_HOST", env: env) == nil)
    }
}
