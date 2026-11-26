import Foundation
import Testing
@testable import CmuxMobileSupport

@Suite struct MobileDebugInformationTests {
    @Test func reportIncludesCorrelationFieldsAndStableOrder() {
        let info = MobileDebugInformation(
            accountID: "user-1",
            installID: "install-1",
            deviceID: "device-1",
            teamID: "team-1",
            bundleID: "dev.cmux.ios",
            appChannel: "dev",
            appVersion: "1.0.0",
            buildNumber: "42",
            osVersion: "18.6",
            deviceModel: "iPhone",
            connectionState: "connected",
            transport: "iroh",
            reportedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(info.report == """
        Account ID: user-1
        Install ID: install-1
        Device ID: device-1
        Team ID: team-1
        Bundle ID: dev.cmux.ios
        App Channel: dev
        App Version: 1.0.0
        Build Number: 42
        iOS Version: 18.6
        Device Model: iPhone
        Connection State: connected
        Transport: iroh
        Reported At (UTC): 1970-01-01T00:00:00Z
        """)
    }

    @Test func reportMarksMissingValuesWithoutLeakingSecrets() {
        let report = MobileDebugInformation().report

        #expect(report.contains("Account ID: <unavailable>"))
        #expect(report.contains("Install ID: <unavailable>"))
        #expect(report.contains("Device ID: <unavailable>"))
        #expect(report.contains("Bundle ID: <unavailable>"))
        #expect(report.contains("Transport: <unavailable>"))
        #expect(!report.contains("access_token"))
        #expect(!report.contains("refresh_token"))
    }
}
