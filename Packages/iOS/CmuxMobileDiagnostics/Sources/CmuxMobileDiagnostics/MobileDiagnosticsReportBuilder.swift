public import Foundation

/// Builds a single secret-scrubbed text report for mobile beta diagnostics.
public struct MobileDiagnosticsReportBuilder: Sendable {
    private let scrubber: MobileDiagnosticsSecretScrubber

    /// Create a report builder.
    ///
    /// - Parameter scrubber: Secret scrubber applied to every report section.
    public init(scrubber: MobileDiagnosticsSecretScrubber = MobileDiagnosticsSecretScrubber()) {
        self.scrubber = scrubber
    }

    /// Build a complete diagnostics report.
    ///
    /// - Parameters:
    ///   - generatedAt: Report generation timestamp.
    ///   - app: App and device metadata.
    ///   - auth: Redacted auth state.
    ///   - connection: Redacted connection state.
    ///   - events: Recent in-app diagnostics events.
    ///   - structuredEventLog: Optional compact structured event log text.
    ///   - debugLog: Optional string debug log text; the shared report includes
    ///     only a count summary, never raw debug-log lines.
    ///   - osLogEntries: Recent current-process unified-log entries; the shared
    ///     report includes only a count summary, never raw OSLog messages.
    /// - Returns: A secret-scrubbed plain-text report.
    public func buildReport(
        generatedAt: Date,
        app: MobileDiagnosticsAppInfo,
        auth: MobileDiagnosticsAuthState,
        connection: MobileDiagnosticsConnectionState,
        events: [MobileDiagnosticsEvent],
        structuredEventLog: String?,
        debugLog: String?,
        osLogEntries: [MobileDiagnosticsOSLogEntry]
    ) -> String {
        let report = rawReport(
            generatedAt: generatedAt,
            app: app,
            auth: auth,
            connection: connection,
            events: events,
            structuredEventLog: structuredEventLog,
            debugLog: debugLog,
            osLogEntries: osLogEntries
        )
        return scrubber.scrub(report)
    }

    private func rawReport(
        generatedAt: Date,
        app: MobileDiagnosticsAppInfo,
        auth: MobileDiagnosticsAuthState,
        connection: MobileDiagnosticsConnectionState,
        events: [MobileDiagnosticsEvent],
        structuredEventLog: String?,
        debugLog: String?,
        osLogEntries: [MobileDiagnosticsOSLogEntry]
    ) -> String {
        var lines: [String] = []
        lines.append(localized("mobile.diagnostics.report.title", defaultValue: "cmux iOS diagnostics"))
        lines.append(
            "\(localized("mobile.diagnostics.report.generated", defaultValue: "Generated")): \(format(generatedAt))"
        )
        lines.append("")
        lines.append(localized("mobile.diagnostics.report.app", defaultValue: "App"))
        lines.append("- \(localized("mobile.diagnostics.report.version", defaultValue: "version")): \(present(app.version))")
        lines.append("- \(localized("mobile.diagnostics.report.build", defaultValue: "build")): \(present(app.build))")
        lines.append(
            "- \(localized("mobile.diagnostics.report.bundle", defaultValue: "bundle")): \(present(app.bundleIdentifier))"
        )
        lines.append(
            "- \(localized("mobile.diagnostics.report.device", defaultValue: "device")): \(present(app.deviceModel))"
        )
        lines.append("- \(localized("mobile.diagnostics.report.os", defaultValue: "os")): \(present(app.osVersion))")
        lines.append("")
        lines.append(localized("mobile.diagnostics.report.auth", defaultValue: "Auth"))
        let authState = auth.isSignedIn
            ? localized("mobile.diagnostics.report.signedIn", defaultValue: "signed_in")
            : localized("mobile.diagnostics.report.signedOut", defaultValue: "signed_out")
        lines.append(
            "- \(localized("mobile.diagnostics.report.state", defaultValue: "state")): \(authState)"
        )
        lines.append(
            "- \(localized("mobile.diagnostics.report.lastError", defaultValue: "last_error")): \(present(auth.lastError))"
        )
        lines.append("")
        lines.append(localized("mobile.diagnostics.report.connection", defaultValue: "Connection"))
        lines.append(
            "- \(localized("mobile.diagnostics.report.state", defaultValue: "state")): \(present(connection.state))"
        )
        lines.append("- \(localized("mobile.diagnostics.report.host", defaultValue: "host")): \(present(connection.host))")
        lines.append(
            "- \(localized("mobile.diagnostics.report.lastError", defaultValue: "last_error")): \(present(connection.lastError))"
        )
        lines.append("")
        appendEvents(events, to: &lines)
        appendBlock(
            title: localized("mobile.diagnostics.report.structuredEventLog", defaultValue: "Structured Event Log"),
            text: structuredEventLog,
            emptyValue: noneValue,
            to: &lines
        )
        appendDebugLog(debugLog, to: &lines)
        appendOSLog(osLogEntries, to: &lines)
        return lines.joined(separator: "\n")
    }

    private func appendEvents(_ events: [MobileDiagnosticsEvent], to lines: inout [String]) {
        lines.append(localized("mobile.diagnostics.report.inAppEventLog", defaultValue: "In-App Event Log"))
        if events.isEmpty {
            lines.append(noneValue)
            lines.append("")
            return
        }
        for event in events {
            let fields = event.fields
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            if fields.isEmpty {
                lines.append("\(format(event.date)) \(event.name)")
            } else {
                lines.append("\(format(event.date)) \(event.name) \(fields)")
            }
        }
        lines.append("")
    }

    private func appendBlock(title: String, text: String?, emptyValue: String, to lines: inout [String]) {
        lines.append(title)
        guard let text = nonEmpty(text) else {
            lines.append(emptyValue)
            lines.append("")
            return
        }
        lines.append(text)
        lines.append("")
    }

    private func appendDebugLog(_ text: String?, to lines: inout [String]) {
        lines.append(localized("mobile.diagnostics.report.debugLog", defaultValue: "Debug Log"))
        guard let text = nonEmpty(text) else {
            lines.append(noneValue)
            lines.append("")
            return
        }
        lines.append(
            String(
                format: localized(
                    "mobile.diagnostics.report.debugLogOmittedFormat",
                    defaultValue: "Debug log lines omitted from shared report: %d"
                ),
                lineCount(text)
            )
        )
        lines.append("")
    }

    private func appendOSLog(_ entries: [MobileDiagnosticsOSLogEntry], to lines: inout [String]) {
        lines.append(localized("mobile.diagnostics.report.recentOSLog", defaultValue: "Recent OSLog"))
        if entries.isEmpty {
            lines.append(noneValue)
            lines.append("")
            return
        }
        lines.append(
            String(
                format: localized(
                    "mobile.diagnostics.report.osLogOmittedFormat",
                    defaultValue: "OSLog entries omitted from shared report: %d"
                ),
                entries.count
            )
        )
        lines.append("")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private var noneValue: String {
        localized("mobile.diagnostics.report.none", defaultValue: "none")
    }

    private func present(_ value: String?) -> String {
        nonEmpty(value) ?? noneValue
    }

    private func lineCount(_ value: String) -> Int {
        let components = value.components(separatedBy: .newlines)
        let count = components.filter { !$0.isEmpty }.count
        return max(count, 1)
    }

    private func localized(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue)
    }

    private func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
