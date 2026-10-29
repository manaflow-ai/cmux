import CmuxFoundation
import CmuxSettings
import Foundation

struct MacSentryStartupPolicy: Sendable {
    let telemetryEnabled: Bool
    let isRunningUnderXCTest: Bool
    let allowUnderXCTest: Bool
    let allowsBuildIdentity: Bool

    init(
        telemetryEnabled: Bool,
        isRunningUnderXCTest: Bool,
        allowUnderXCTest: Bool,
        allowsBuildIdentity: Bool
    ) {
        self.telemetryEnabled = telemetryEnabled
        self.isRunningUnderXCTest = isRunningUnderXCTest
        self.allowUnderXCTest = allowUnderXCTest
        self.allowsBuildIdentity = allowsBuildIdentity
    }

    init(
        environment: [String: String],
        telemetryEnabled: Bool,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.init(
            telemetryEnabled: telemetryEnabled,
            isRunningUnderXCTest: Self.isRunningUnderXCTest(environment: environment),
            allowUnderXCTest: environment["CMUX_TEST_SENTRY_ENABLED"] == "1",
            // The cmux repo is public; rebranded forks have shipped with the
            // hardcoded cmux DSN intact (Sentry issue CMUXTERM-MACOS-1RZF).
            // Only a build that identifies as cmux may start Sentry.
            allowsBuildIdentity: SentryBuildIdentityPolicy(
                bundleIdentifier: bundleIdentifier,
                trustedBaseBundleIdentifier: SocketPathMarkerFiles.stableBundleIdentifier
            ).allowsTelemetry
        )
    }

    var shouldStart: Bool {
        telemetryEnabled && allowsBuildIdentity && (!isRunningUnderXCTest || allowUnderXCTest)
    }

    static func isRunningUnderXCTest(environment: [String: String]) -> Bool {
        // xcodebuild strips TEST_RUNNER_ from variables forwarded to the test
        // host, so the CI wrapper makes this available before XCTest connects.
        if environment["CMUX_TEST_PROCESS"] == "1" { return true }
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestBundlePath"] != nil { return true }
        if environment["XCTestSessionIdentifier"] != nil { return true }
        if environment["XCInjectBundle"] != nil { return true }
        if environment["XCInjectBundleInto"] != nil { return true }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) { return true }
        return false
    }
}
