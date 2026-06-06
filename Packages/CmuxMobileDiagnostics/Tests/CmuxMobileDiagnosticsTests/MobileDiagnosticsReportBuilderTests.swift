import Foundation
import Testing
@testable import CmuxMobileDiagnostics

@Suite struct MobileDiagnosticsReportBuilderTests {
    private func makeBuilder(
        sink: MobileDebugLogSink = MobileDebugLogSink(),
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> MobileDiagnosticsReportBuilder {
        let env = MobileDiagnosticsEnvironment(
            appName: "cmux",
            appVersion: "0.64.0",
            buildNumber: "123",
            bundleID: "dev.cmux.ios",
            deviceModel: "iPhone16,2",
            osVersion: "iOS 18.4"
        )
        return MobileDiagnosticsReportBuilder(
            environment: env,
            sink: sink,
            now: { now }
        )
    }

    private func makeState(
        lastAuthError: String? = "Network error. Please check your connection."
    ) -> MobileDiagnosticsLiveState {
        MobileDiagnosticsLiveState(
            connectionState: "connected",
            isSignedIn: true,
            isAuthenticated: true,
            lastAuthError: lastAuthError,
            connectedHostName: "studio.local",
            pairedMacName: "Studio",
            pairedMacDeviceID: "MAC-DEVICE-1",
            connectionError: nil
        )
    }

    @Test func reportContainsHeaderFields() async {
        let builder = makeBuilder()
        let report = await builder.composeReportScrubbed(
            liveState: makeState(),
            logCount: 2,
            logBody: "line one\nline two",
            osLog: "(no matching os log entries in the last 300s)",
            terminalSnapshot: "$ echo ok\nok"
        )

        #expect(report.contains("cmux iOS Diagnostics"))
        #expect(report.contains("App:        cmux"))
        #expect(report.contains("Version:    0.64.0 (build 123)"))
        #expect(report.contains("Bundle ID:  dev.cmux.ios"))
        #expect(report.contains("Device:     iPhone16,2"))
        #expect(report.contains("OS:         iOS 18.4"))
    }

    @Test func reportContainsAllSectionLabels() async {
        let builder = makeBuilder()
        let report = await builder.composeReportScrubbed(
            liveState: makeState(),
            logCount: 2,
            logBody: "line one\nline two",
            osLog: "osline",
            terminalSnapshot: "termtext"
        )

        #expect(report.contains("LIVE STATE"))
        #expect(report.contains("IN-PROCESS LOG (2 lines)"))
        #expect(report.contains("OS LOG (last 5 min, best-effort)"))
        #expect(report.contains("VISIBLE TERMINAL SNAPSHOT"))
        // Live-state body and the section bodies are present.
        #expect(report.contains("Connection:      connected"))
        #expect(report.contains("Signed in:       yes"))
        #expect(report.contains("Last auth error: Network error. Please check your connection."))
        #expect(report.contains("Connected host:  studio.local"))
        #expect(report.contains("line one"))
        #expect(report.contains("termtext"))
    }

    @Test func scrubRedactsBearerTokenButKeepsHeaderIdentifiers() async {
        let builder = makeBuilder()
        let report = await builder.composeReportScrubbed(
            liveState: makeState(),
            logCount: 1,
            logBody: "Authorization: Bearer abc.def.ghijklmnop",
            osLog: "(none)",
            terminalSnapshot: nil
        )

        // Positive: the bearer token value is masked.
        #expect(report.contains("Bearer <redacted>"))
        #expect(!report.contains("abc.def.ghijklmnop"))

        // Negative: dotted identifiers and version strings in the header survive.
        #expect(report.contains("dev.cmux.ios"))
        #expect(!report.contains("dev.cmux.<redacted>"))
        #expect(report.contains("0.64.0 (build 123)"))
        #expect(report.contains("iPhone16,2"))
        #expect(report.contains("iOS 18.4"))
    }

    @Test func reportRedactsBasicAuthorizationHeader() async {
        let builder = makeBuilder()
        let basicCredential = "dXNlcjpwYXNzd29yZA=="
        let report = await builder.composeReportScrubbed(
            liveState: makeState(),
            logCount: 1,
            logBody: "curl -H 'Authorization: Basic \(basicCredential)' https://example.com",
            osLog: "(none)",
            terminalSnapshot: "$ curl -H 'Authorization: Basic \(basicCredential)' https://example.com"
        )

        #expect(report.contains("Authorization: Basic <redacted>"))
        #expect(!report.contains(basicCredential))
    }

    @Test func emptyTerminalSnapshotShowsPlaceholder() async {
        let builder = makeBuilder()
        let report = await builder.composeReportScrubbed(
            liveState: makeState(lastAuthError: nil),
            logCount: 0,
            logBody: "",
            osLog: "(none)",
            terminalSnapshot: nil
        )
        #expect(report.contains("(no visible terminal)"))
        #expect(report.contains("(empty)"))
        #expect(report.contains("Last auth error: (none)"))
    }

    @Test func buildReportReturnsScrubbedTextWithoutPersistingIt() async {
        let builder = makeBuilder()
        let report = await builder.buildReport(
            liveState: makeState(),
            terminalSnapshot: "token=ghp_abcdefghijklmnopqrstuvwxyz012345"
        )

        #expect(report.text.contains("VISIBLE TERMINAL SNAPSHOT"))
        #expect(report.text.contains("token=<redacted>"))
        #expect(!report.text.contains("ghp_abcdefghijklmnopqrstuvwxyz012345"))
    }

    @Test func buildReportIncludesPendingImmediateEvents() async {
        let builder = makeBuilder()
        let report = await builder.buildReport(
            liveState: makeState(),
            terminalSnapshot: nil,
            immediateEventLines: ["conn.state=connected host=studio.local"]
        )

        #expect(report.text.contains("IN-PROCESS LOG (1 lines)"))
        #expect(report.text.contains("[pending] conn.state=connected host=studio.local"))
    }

    @Test func buildReportDoesNotDuplicateImmediateEventsAlreadyInSink() async {
        let sink = MobileDebugLogSink()
        await sink.append("conn.state=connected host=studio.local")
        let builder = makeBuilder(sink: sink)
        let report = await builder.buildReport(
            liveState: makeState(),
            terminalSnapshot: nil,
            immediateEventLines: ["conn.state=connected host=studio.local"]
        )

        #expect(report.text.contains("IN-PROCESS LOG (1 lines)"))
        #expect(!report.text.contains("[pending] conn.state=connected host=studio.local"))
    }

    @Test func defaultOSLogSubsystemsIncludeBetaAndRootSceneSubsystems() {
        let subsystems = MobileDiagnosticsOSLogReader.defaultSubsystems

        #expect(subsystems.contains("dev.cmux.ios"))
        #expect(subsystems.contains("ai.manaflow.cmux.ios"))
    }
}
