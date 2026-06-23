import Testing
import Foundation
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

    // MARK: - dogfoodAttachURL (NOT mock-gated)

    /// The core P2 fix: the dogfood attach URL must be returned even when mock data
    /// is off (the real-backend dev-launch path), so iOS auto-pair actually fires.
    @Test func dogfoodAttachURLReturnedWithMockDisabled() {
        let env = [
            "CMUX_UITEST_MOCK_DATA": "0",
            "CMUX_DOGFOOD_ATTACH_URL": "cmux-ios://attach?v=1&payload=abc",
        ]
        #if DEBUG
        #expect(UITestConfig.dogfoodAttachURL(from: env) == "cmux-ios://attach?v=1&payload=abc")
        #else
        #expect(UITestConfig.dogfoodAttachURL(from: env) == nil)
        #endif
    }

    /// Regression guard: with mock off, the legacy mock-gated `attachURL`
    /// (`CMUX_UITEST_ATTACH_URL`) stays nil, which is exactly why the dedicated
    /// dogfood accessor is required for the real-backend auto-pair path.
    @Test func legacyAttachURLStaysNilWithMockDisabledButDogfoodDoesNot() {
        let env = [
            "CMUX_UITEST_MOCK_DATA": "0",
            "CMUX_UITEST_ATTACH_URL": "cmux-ios://attach?v=1&payload=legacy",
            "CMUX_DOGFOOD_ATTACH_URL": "cmux-ios://attach?v=1&payload=dogfood",
        ]
        #expect(UITestConfig.value(for: "CMUX_UITEST_ATTACH_URL", env: env) == nil)
        #if DEBUG
        #expect(UITestConfig.dogfoodAttachURL(from: env) == "cmux-ios://attach?v=1&payload=dogfood")
        #else
        #expect(UITestConfig.dogfoodAttachURL(from: env) == nil)
        #endif
    }

    @Test func dogfoodAttachURLIsTrimmed() {
        let env = ["CMUX_DOGFOOD_ATTACH_URL": "  cmux-ios://attach?v=1&payload=zzz  "]
        #if DEBUG
        #expect(UITestConfig.dogfoodAttachURL(from: env) == "cmux-ios://attach?v=1&payload=zzz")
        #else
        #expect(UITestConfig.dogfoodAttachURL(from: env) == nil)
        #endif
    }

    @Test func dogfoodAttachURLCanComeFromLaunchArgument() {
        let arguments = [
            "/path/cmux",
            "--cmux-dogfood-attach-url",
            "  cmux-ios-dev://attach?v=1&payload=arg  ",
        ]
        #if DEBUG
        #expect(
            UITestConfig.dogfoodAttachURL(from: [:], arguments: arguments)
                == "cmux-ios-dev://attach?v=1&payload=arg"
        )
        #else
        #expect(UITestConfig.dogfoodAttachURL(from: [:], arguments: arguments) == nil)
        #endif
    }

    @Test func dogfoodAttachURLEnvironmentWinsOverLaunchArgument() {
        let env = ["CMUX_DOGFOOD_ATTACH_URL": "cmux-ios://attach?v=1&payload=env"]
        let arguments = [
            "/path/cmux",
            "--cmux-dogfood-attach-url",
            "cmux-ios-dev://attach?v=1&payload=arg",
        ]
        #if DEBUG
        #expect(
            UITestConfig.dogfoodAttachURL(from: env, arguments: arguments)
                == "cmux-ios://attach?v=1&payload=env"
        )
        #else
        #expect(UITestConfig.dogfoodAttachURL(from: env, arguments: arguments) == nil)
        #endif
    }

    @Test func dogfoodAttachURLCanComeFromUserDefaults() {
        let (suiteName, defaults) = temporaryDefaults()
        defaults.set("  cmux-ios-dev://attach?v=1&payload=defaults  ", forKey: "CMUX_DOGFOOD_ATTACH_URL")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #if DEBUG
        #expect(
            UITestConfig.dogfoodAttachURL(from: [:], defaults: defaults)
                == "cmux-ios-dev://attach?v=1&payload=defaults"
        )
        #else
        #expect(UITestConfig.dogfoodAttachURL(from: [:], defaults: defaults) == nil)
        #endif
    }

    @Test func dogfoodAttachURLLaunchArgumentWinsOverUserDefaults() {
        let (suiteName, defaults) = temporaryDefaults()
        defaults.set("cmux-ios-dev://attach?v=1&payload=defaults", forKey: "CMUX_DOGFOOD_ATTACH_URL")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let arguments = [
            "/path/cmux",
            "--cmux-dogfood-attach-url",
            "cmux-ios-dev://attach?v=1&payload=arg",
        ]

        #if DEBUG
        #expect(
            UITestConfig.dogfoodAttachURL(from: [:], arguments: arguments, defaults: defaults)
                == "cmux-ios-dev://attach?v=1&payload=arg"
        )
        #else
        #expect(UITestConfig.dogfoodAttachURL(from: [:], arguments: arguments, defaults: defaults) == nil)
        #endif
    }

    @Test func dogfoodAttachURLIsNilWhenLaunchArgumentValueIsMissingOrBlank() {
        #expect(
            UITestConfig.dogfoodAttachURL(
                from: [:],
                arguments: ["/path/cmux", "--cmux-dogfood-attach-url"]
            ) == nil
        )
        #expect(
            UITestConfig.dogfoodAttachURL(
                from: [:],
                arguments: ["/path/cmux", "--cmux-dogfood-attach-url", "   "]
            ) == nil
        )
    }

    @Test func dogfoodAttachURLIsNilWhenAbsent() {
        #expect(UITestConfig.dogfoodAttachURL(from: [:]) == nil)
    }

    @Test func dogfoodAttachURLIsNilWhenBlank() {
        let env = ["CMUX_DOGFOOD_ATTACH_URL": "   "]
        #expect(UITestConfig.dogfoodAttachURL(from: env) == nil)
    }

    private func temporaryDefaults() -> (String, UserDefaults) {
        let name = defaultsSuiteName
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (name, defaults)
    }

    private var defaultsSuiteName: String {
        "UITestConfigTests.\(UUID().uuidString)"
    }
}
