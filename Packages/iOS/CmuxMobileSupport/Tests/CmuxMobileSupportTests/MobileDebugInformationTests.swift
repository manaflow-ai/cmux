import Testing
@testable import CmuxMobileSupport

@Suite struct MobileDebugInformationTests {
    @Test func reportIncludesCorrelationFieldsAndStableOrder() {
        let info = MobileDebugInformation(
            deviceID: "device-1",
            email: "person@example.com",
            hexclaveAuthID: "user-1",
            teamID: "team-1",
            bundleID: "com.cmux.app",
            appVersion: "1.0.0",
            buildNumber: "42",
            osVersion: "26.0",
            deviceModel: "iPhone",
            analyticsClientID: "client-1",
            connectedHost: "Mac",
            connectionState: "connected",
            transport: "iroh"
        )

        #expect(info.report == """
        Device ID: device-1
        Email: person@example.com
        Hexclave Auth ID: user-1
        Team ID: team-1
        Bundle ID: com.cmux.app
        App Version: 1.0.0
        Build Number: 42
        iOS Version: 26.0
        Device Model: iPhone
        Analytics Client ID: client-1
        Connected Host: Mac
        Connection State: connected
        Transport: iroh
        """)
    }

    @Test func reportMarksMissingValuesWithoutLeakingSecrets() {
        let report = MobileDebugInformation(email: "person@example.com").report

        #expect(report.contains("Email: person@example.com"))
        #expect(report.contains("Device ID: <unavailable>"))
        #expect(!report.contains("access_token"))
        #expect(!report.contains("refresh_token"))
    }
}
