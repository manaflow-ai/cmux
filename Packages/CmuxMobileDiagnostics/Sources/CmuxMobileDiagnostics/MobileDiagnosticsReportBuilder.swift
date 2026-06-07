public import Foundation

/// Assembles a single-text diagnostics bundle for a TestFlight beta tester to
/// export from the iOS app.
///
/// The report is intentionally a *secrets-exfiltration surface*: it includes the
/// visible terminal snapshot (which can contain live tokens/keys/env/source) and
/// the in-process log, because those are what make a beta bug report actionable.
/// To make sharing it safer, the whole assembled bundle is passed through
/// ``MobileDiagnosticsSecretScrubber`` before it is returned.
///
/// Sections, in order: header (app/device facts), live state, in-process log
/// (PRIMARY, from ``MobileDebugLogSink/snapshotWithCount()``), OS log supplement
/// (best-effort, from ``MobileDiagnosticsOSLogReader``), and the visible terminal
/// snapshot (clearly section-labeled).
///
/// I/O (the sink snapshot and the OS-log read) happens off the caller via
/// `async`; the builder is an `actor` so concurrent build requests serialize.
///
/// ```swift
/// let environment = await MobileDiagnosticsEnvironment.current()
/// let builder = MobileDiagnosticsReportBuilder(
///     environment: environment,
///     sink: MobileDebugLog.shared.sink
/// )
/// let report = await builder.buildReport(
///     liveState: state,
///     terminalSnapshot: visibleText
/// )
/// // report.text -> scrubbed string for clipboard, ShareLink, and feedback
/// ```
public actor MobileDiagnosticsReportBuilder {
    private let environment: MobileDiagnosticsEnvironment
    private let sink: MobileDebugLogSink
    private let osLogReader: MobileDiagnosticsOSLogReader
    private let scrubber: MobileDiagnosticsSecretScrubber
    private let now: @Sendable () -> Date

    private static let sectionRule = String(repeating: "=", count: 60)

    /// Creates a report builder.
    ///
    /// - Parameters:
    ///   - environment: Static app/device facts for the header. Capture this on
    ///     the main actor via ``MobileDiagnosticsEnvironment/current()`` or pin
    ///     it in tests.
    ///   - sink: The PRIMARY in-process log buffer to snapshot.
    ///   - osLogReader: Best-effort OS-log supplement reader. Defaults to a fresh
    ///     reader over the cmux subsystem set.
    ///   - scrubber: Secret scrubber applied to the whole bundle. Defaults to the
    ///     standard ``MobileDiagnosticsSecretScrubber``.
    ///   - now: Clock used for the report timestamp. Injected for deterministic
    ///     tests; defaults to `Date.init`.
    public init(
        environment: MobileDiagnosticsEnvironment,
        sink: MobileDebugLogSink,
        osLogReader: MobileDiagnosticsOSLogReader = MobileDiagnosticsOSLogReader(),
        scrubber: MobileDiagnosticsSecretScrubber = MobileDiagnosticsSecretScrubber(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.sink = sink
        self.osLogReader = osLogReader
        self.scrubber = scrubber
        self.now = now
    }

    /// Build and scrub the diagnostics report.
    ///
    /// - Parameters:
    ///   - liveState: Decoupled snapshot of the shell's runtime state.
    ///   - terminalSnapshot: The visible terminal text, or `nil`/empty if none.
    /// - Returns: The scrubbed report text.
    public func buildReport(
        liveState: MobileDiagnosticsLiveState,
        terminalSnapshot: String?,
        immediateEventLines: [String] = [],
        osLogNotBefore: Date? = nil
    ) async -> MobileDiagnosticsReport {
        let (logCount, logBody) = await sink.snapshotWithCount()
        let osLog = await osLogReader.recentEntriesText(notBefore: osLogNotBefore)
        let pendingImmediateEvents = immediateEventLines
            .filter { event in logBody.contains(event) == false }
            .map { "[pending] \($0)" }
        let immediateEventBody = pendingImmediateEvents.joined(separator: "\n")
        let combinedLogBody = [logBody, immediateEventBody]
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")

        let raw = composeReport(
            liveState: liveState,
            logCount: logCount + pendingImmediateEvents.count,
            logBody: combinedLogBody,
            osLog: osLog,
            terminalSnapshot: terminalSnapshot
        )
        let scrubbed = scrubber.scrub(raw)
        return MobileDiagnosticsReport(text: scrubbed)
    }

    /// Compose the report text from already-resolved pieces (no I/O), scrubbed.
    ///
    /// `internal` (not `public`): it exists so tests (`@testable import`) can
    /// assert the formatting and the scrub directly without an OS-log store or a
    /// live sink. Feed fixed inputs and inspect the returned text.
    ///
    /// - Parameters:
    ///   - liveState: The runtime state snapshot.
    ///   - logCount: Number of buffered in-process log lines.
    ///   - logBody: The newline-joined in-process log body.
    ///   - osLog: The OS-log supplement text (or unavailability note).
    ///   - terminalSnapshot: The visible terminal text, or `nil`/empty.
    /// - Returns: The assembled report text, already scrubbed.
    func composeReportScrubbed(
        liveState: MobileDiagnosticsLiveState,
        logCount: Int,
        logBody: String,
        osLog: String,
        terminalSnapshot: String?
    ) -> String {
        scrubber.scrub(
            composeReport(
                liveState: liveState,
                logCount: logCount,
                logBody: logBody,
                osLog: osLog,
                terminalSnapshot: terminalSnapshot
            )
        )
    }

    /// Assemble the unscrubbed report text from resolved pieces.
    private func composeReport(
        liveState: MobileDiagnosticsLiveState,
        logCount: Int,
        logBody: String,
        osLog: String,
        terminalSnapshot: String?
    ) -> String {
        var sections: [String] = []
        sections.append(headerSection())
        sections.append(liveStateSection(liveState))
        sections.append(
            section(
                title: MobileDiagnosticsL10n.format(
                    "mobile.diagnostics.report.inProcessLog.title",
                    defaultValue: "IN-PROCESS LOG (%d lines)",
                    logCount
                ),
                body: logBody.isEmpty
                    ? MobileDiagnosticsL10n.string("mobile.diagnostics.report.empty", defaultValue: "(empty)")
                    : logBody
            )
        )
        sections.append(
            section(
                title: MobileDiagnosticsL10n.string(
                    "mobile.diagnostics.report.osLog.title",
                    defaultValue: "OS LOG (last 5 min, best-effort)"
                ),
                body: osLog
            )
        )
        let terminal = (terminalSnapshot?.isEmpty == false)
            ? terminalSnapshot!
            : MobileDiagnosticsL10n.string(
                "mobile.diagnostics.report.noVisibleTerminal",
                defaultValue: "(no visible terminal)"
            )
        sections.append(
            section(
                title: MobileDiagnosticsL10n.string(
                    "mobile.diagnostics.report.visibleTerminal.title",
                    defaultValue: "VISIBLE TERMINAL SNAPSHOT (may contain sensitive output)"
                ),
                body: terminal
            )
        )
        return sections.joined(separator: "\n\n")
    }

    /// The report header with app/device facts and a timestamp.
    private func headerSection() -> String {
        let formatter = ISO8601DateFormatter()
        let lines = [
            MobileDiagnosticsL10n.string(
                "mobile.diagnostics.report.title",
                defaultValue: "cmux iOS Diagnostics"
            ),
            Self.sectionRule,
            MobileDiagnosticsL10n.format(
                "mobile.diagnostics.report.app",
                defaultValue: "App:        %@",
                environment.appName
            ),
            MobileDiagnosticsL10n.format(
                "mobile.diagnostics.report.version",
                defaultValue: "Version:    %@ (build %@)",
                environment.appVersion,
                environment.buildNumber
            ),
            MobileDiagnosticsL10n.format(
                "mobile.diagnostics.report.bundleID",
                defaultValue: "Bundle ID:  %@",
                environment.bundleID
            ),
            MobileDiagnosticsL10n.format(
                "mobile.diagnostics.report.device",
                defaultValue: "Device:     %@",
                environment.deviceModel
            ),
            MobileDiagnosticsL10n.format(
                "mobile.diagnostics.report.os",
                defaultValue: "OS:         %@",
                environment.osVersion
            ),
            MobileDiagnosticsL10n.format(
                "mobile.diagnostics.report.generated",
                defaultValue: "Generated:  %@",
                formatter.string(from: now())
            ),
        ]
        return lines.joined(separator: "\n")
    }

    /// The live runtime-state section.
    private func liveStateSection(_ state: MobileDiagnosticsLiveState) -> String {
        let yes = MobileDiagnosticsL10n.string("mobile.diagnostics.report.yes", defaultValue: "yes")
        let no = MobileDiagnosticsL10n.string("mobile.diagnostics.report.no", defaultValue: "no")
        let none = MobileDiagnosticsL10n.string("mobile.diagnostics.report.none", defaultValue: "(none)")
        var lines = [
            MobileDiagnosticsL10n.format(
                "mobile.diagnostics.report.connection",
                defaultValue: "Connection:      %@",
                state.connectionState
            ),
            MobileDiagnosticsL10n.format(
                "mobile.diagnostics.report.signedIn",
                defaultValue: "Signed in:       %@",
                state.isSignedIn ? yes : no
            ),
            MobileDiagnosticsL10n.format(
                "mobile.diagnostics.report.authenticated",
                defaultValue: "Authenticated:   %@",
                state.isAuthenticated ? yes : no
            ),
            MobileDiagnosticsL10n.format(
                "mobile.diagnostics.report.lastAuthError",
                defaultValue: "Last auth error: %@",
                state.lastAuthError ?? none
            ),
            MobileDiagnosticsL10n.format(
                "mobile.diagnostics.report.connectedHost",
                defaultValue: "Connected host:  %@",
                state.connectedHostName ?? none
            ),
            MobileDiagnosticsL10n.format(
                "mobile.diagnostics.report.pairedMac",
                defaultValue: "Paired Mac:      %@",
                state.pairedMacName ?? none
            ),
        ]
        if let deviceID = state.pairedMacDeviceID {
            lines.append(
                MobileDiagnosticsL10n.format(
                    "mobile.diagnostics.report.pairedMacID",
                    defaultValue: "Paired Mac ID:   %@",
                    deviceID
                )
            )
        }
        if let error = state.connectionError {
            lines.append(
                MobileDiagnosticsL10n.format(
                    "mobile.diagnostics.report.lastError",
                    defaultValue: "Last error:      %@",
                    error
                )
            )
        }
        return section(
            title: MobileDiagnosticsL10n.string("mobile.diagnostics.report.liveState.title", defaultValue: "LIVE STATE"),
            body: lines.joined(separator: "\n")
        )
    }

    /// Render one labeled section with a rule under the title.
    private func section(title: String, body: String) -> String {
        "\(title)\n\(Self.sectionRule)\n\(body)"
    }

}
