import Foundation
import Testing
@testable import CmuxMobileDiagnostics

@Suite struct MobileDiagnosticsReportBuilderTests {
    @Test func reportIncludesRequestedSectionsAndScrubsSecrets() {
        let builder = MobileDiagnosticsReportBuilder()
        let report = builder.buildReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            app: MobileDiagnosticsAppInfo(
                version: "1.2.3",
                build: "456",
                bundleIdentifier: "com.cmux.test",
                deviceModel: "iPhone17,2",
                osVersion: "iOS 26.0"
            ),
            auth: MobileDiagnosticsAuthState(isSignedIn: true, lastError: "AuthError.networkError"),
            connection: MobileDiagnosticsConnectionState(
                state: "connected",
                host: "mac.local",
                lastError: "Authorization: Bearer abcdefghijklmnop"
            ),
            events: [
                MobileDiagnosticsEvent(
                    date: Date(timeIntervalSince1970: 1_700_000_010),
                    name: "conn.error",
                    fields: ["message": "refresh_token=supersecret"]
                ),
            ],
            structuredEventLog: "cmuxdiag v1 count=1\n1000,1,,,,,",
            debugLog: "user me@example.com access_token=topsecret",
            osLogEntries: [
                MobileDiagnosticsOSLogEntry(
                    date: Date(timeIntervalSince1970: 1_700_000_020),
                    subsystem: "dev.cmux.ios",
                    category: "auth",
                    level: "error",
                    message: "jwt aaaabbbbccccdddd.eeeeffffgggghhhh.iiiijjjjkkkkllll"
                ),
            ]
        )

        #expect(report.contains("App"))
        #expect(report.contains("- version: 1.2.3"))
        #expect(report.contains("Auth"))
        #expect(report.contains("- state: signed_in"))
        #expect(report.contains("Connection"))
        #expect(report.contains("In-App Event Log"))
        #expect(report.contains("Structured Event Log"))
        #expect(report.contains("Debug Log"))
        #expect(report.contains("Recent OSLog"))
        #expect(!report.contains("abcdefghijklmnop"))
        #expect(!report.contains("supersecret"))
        #expect(!report.contains("me@example.com"))
        #expect(!report.contains("topsecret"))
        #expect(!report.contains("aaaabbbbccccdddd"))
        #expect(report.contains("<redacted>"))
    }
}
