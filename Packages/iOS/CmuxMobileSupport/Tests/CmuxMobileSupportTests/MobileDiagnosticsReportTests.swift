import Testing
@testable import CmuxMobileSupport

@Suite struct MobileDiagnosticsReportTests {
    @Test func builderFormatsRowsInDisplayOrder() {
        let snapshot = MobileDiagnosticsReportSnapshot(
            title: "Diagnostics",
            appVersionLabel: "App",
            appVersion: "1.2.3 (456)",
            buildStampLabel: "Build",
            buildStamp: "dev · abc123",
            rows: [
                MobileDiagnosticsReportRow(
                    id: "Account",
                    label: "Account",
                    value: "user@example.com",
                    status: .pass
                ),
                MobileDiagnosticsReportRow(
                    id: "Connection",
                    label: "Connection",
                    value: "Connected · tailscale · 100.64.0.1:51000",
                    status: .pass
                ),
            ]
        )

        let report = MobileDiagnosticsReportBuilder().build(from: snapshot)

        #expect(report.plainText == """
        Diagnostics
        App: 1.2.3 (456)
        Build: dev · abc123

        Account: user@example.com
        Connection: Connected · tailscale · 100.64.0.1:51000
        """)
    }
}
