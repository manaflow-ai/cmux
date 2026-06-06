import Foundation
import Testing
@testable import CmuxMobileDiagnostics

@Suite struct MobileDiagnosticsReportBuilderTests {
    private func makeBuilder(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> MobileDiagnosticsReportBuilder {
        makeBuilder(now: now, temporaryDirectory: FileManager.default.temporaryDirectory)
    }

    private func makeBuilder(
        now: Date = Date(timeIntervalSince1970: 1_700_000_000),
        temporaryDirectory: URL
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
            sink: MobileDebugLogSink(),
            now: { now },
            temporaryDirectory: temporaryDirectory
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

    @Test func buildReportWritesUniqueShareFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-diagnostics-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let builder = makeBuilder(temporaryDirectory: directory)
        let first = await builder.buildReport(liveState: makeState(), terminalSnapshot: "first")
        let second = await builder.buildReport(liveState: makeState(), terminalSnapshot: "second")

        #expect(first.fileURL.lastPathComponent.hasPrefix("cmux-diagnostics-"))
        #expect(second.fileURL.lastPathComponent.hasPrefix("cmux-diagnostics-"))
        #expect(first.fileURL != second.fileURL)
        let firstText = try String(contentsOf: first.fileURL, encoding: .utf8)
        let secondText = try String(contentsOf: second.fileURL, encoding: .utf8)
        #expect(firstText.contains("first"))
        #expect(secondText.contains("second"))
    }
}

@Suite struct MobileDiagnosticsSecretScrubberTests {
    private let scrubber = MobileDiagnosticsSecretScrubber()

    @Test func redactsBearerToken() {
        let out = scrubber.scrub("Authorization: Bearer abcDEF123.ghi_jkl-mno")
        #expect(out == "Authorization: Bearer <redacted>")
    }

    @Test func redactsJwtLikeTriple() {
        let jwt = "eyJhbGciOi.eyJzdWIiOiI.SflKxwRJSM"
        let out = scrubber.scrub("token is \(jwt) here")
        #expect(!out.contains(jwt))
        #expect(out.contains("<redacted>"))
    }

    @Test func redactsKeyValueSecrets() {
        #expect(scrubber.scrub("password=hunter2longvalue").contains("<redacted>"))
        #expect(!scrubber.scrub("password=hunter2longvalue").contains("hunter2longvalue"))
        #expect(scrubber.scrub("token=abcd1234efgh").contains("<redacted>"))
        #expect(scrubber.scrub("api_key: \"sekret-value-here\"").contains("<redacted>"))
    }

    @Test func redactsFirstQueryStringSecrets() {
        let accessTokenURL = "https://example.com/callback?access_token=abcd1234efgh&ok=1"
        let apiKeyURL = "https://example.com/search?api_key=sekretvalue123&q=cmux"

        let scrubbedAccessTokenURL = scrubber.scrub(accessTokenURL)
        let scrubbedAPIKeyURL = scrubber.scrub(apiKeyURL)

        #expect(scrubbedAccessTokenURL.contains("access_token=<redacted>"))
        #expect(scrubbedAPIKeyURL.contains("api_key=<redacted>"))
        #expect(!scrubbedAccessTokenURL.contains("abcd1234efgh"))
        #expect(!scrubbedAPIKeyURL.contains("sekretvalue123"))
    }

    @Test func redactsProviderPrefixedKeys() {
        #expect(scrubber.scrub("sk-abcdefghij0123456789xyz").contains("<redacted>"))
        #expect(scrubber.scrub("ghp_abcdefghij0123456789abcdef").contains("<redacted>"))
    }

    @Test func redactsUpperSnakeEnvVarSecrets() {
        // The dominant shape in `env` / `.env` / `printenv` output that a terminal
        // snapshot captures: an UPPER_SNAKE name has no `\b` boundary before the
        // secret keyword, so this guards against the value leaking even when it
        // is otherwise opaque (no provider prefix).
        for sample in [
            "API_TOKEN=plainopaquevalue123",
            "GITHUB_TOKEN=abcd1234efgh",
            "DB_PASSWORD=plainvalue123",
            "STACK_REFRESH_TOKEN=opaquevalue9999",
            "AWS_SECRET=plainsecret456",
        ] {
            let out = scrubber.scrub(sample)
            #expect(out.contains("<redacted>"), "expected redaction for \(sample), got \(out)")
            #expect(!out.contains("plain"), "value leaked for \(sample): \(out)")
            #expect(!out.contains("abcd1234efgh"))
            #expect(!out.contains("opaquevalue9999"))
        }
    }

    @Test func redactsCanonicalAWSCredentialEnvironmentVariables() {
        let samples = [
            ("AWS_ACCESS_KEY_ID=AKIAIOSDIAGNOSTICS123", "AKIAIOSDIAGNOSTICS123"),
            ("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "wJalrXUtnFEMI"),
            ("AWS_SESSION_TOKEN=IQoJb3JpZ2luX2VjEFAaCXVzLXdlc3QtMiJHMEUCIQD", "IQoJb3JpZ2lu"),
            ("AWS_SECURITY_TOKEN=legacySecurityTokenValue123", "legacySecurityTokenValue123"),
        ]

        for (sample, leakedFragment) in samples {
            let out = scrubber.scrub(sample)
            #expect(out.contains("<redacted>"), "expected redaction for \(sample), got \(out)")
            #expect(out.contains(sample.split(separator: "=")[0]))
            #expect(!out.contains(leakedFragment), "value leaked for \(sample): \(out)")
        }
    }

    @Test func doesNotRedactKeywordSubstrings() {
        // `tokenizer` / `mytokenstuff` contain "token" but are not the keyword,
        // so the trailing `\b` and the separator-terminated prefix must reject them.
        #expect(scrubber.scrub("tokenizer=gpt2") == "tokenizer=gpt2")
        #expect(scrubber.scrub("mytokenstuff=value") == "mytokenstuff=value")
    }

    @Test func preservesDottedIdentifiers() {
        // Bundle ids, hostnames, short version strings must not be masked.
        for sample in ["dev.cmux.ios", "ai.manaflow.cmux.ios", "studio.local", "1.2.3", "0.64.0"] {
            #expect(scrubber.scrub(sample) == sample)
        }
    }

    @Test func preservesNormalTerminalOutput() {
        let sample = "$ ls -la\ntotal 8\ndrwxr-xr-x  3 user staff   96 Jun  5 16:00 ."
        #expect(scrubber.scrub(sample) == sample)
    }
}

@Suite struct MobileDiagnosticsOSLogReaderTests {
    @Test func appendCappedLineStopsAtEntryLimit() {
        var lines: [String] = []
        var bytes = 0

        #expect(MobileDiagnosticsOSLogReader.appendCappedLine("one", to: &lines, renderedBytes: &bytes, maxEntries: 1, maxBytes: 100))
        #expect(!MobileDiagnosticsOSLogReader.appendCappedLine("two", to: &lines, renderedBytes: &bytes, maxEntries: 1, maxBytes: 100))
        #expect(lines == ["one"])
    }

    @Test func appendCappedLineStopsAtByteLimit() {
        var lines: [String] = []
        var bytes = 0

        #expect(MobileDiagnosticsOSLogReader.appendCappedLine("one", to: &lines, renderedBytes: &bytes, maxEntries: 10, maxBytes: 7))
        #expect(!MobileDiagnosticsOSLogReader.appendCappedLine("three", to: &lines, renderedBytes: &bytes, maxEntries: 10, maxBytes: 7))
        #expect(lines == ["one"])
    }
}
