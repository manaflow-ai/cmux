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
    ///   - debugLog: Optional string debug log text.
    ///   - osLogEntries: Recent current-process unified-log entries.
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
        lines.append("cmux iOS diagnostics")
        lines.append("Generated: \(format(generatedAt))")
        lines.append("")
        lines.append("App")
        lines.append("- version: \(app.version)")
        lines.append("- build: \(app.build)")
        lines.append("- bundle: \(app.bundleIdentifier)")
        lines.append("- device: \(app.deviceModel)")
        lines.append("- os: \(app.osVersion)")
        lines.append("")
        lines.append("Auth")
        lines.append("- state: \(auth.isSignedIn ? "signed_in" : "signed_out")")
        lines.append("- last_error: \(nonEmpty(auth.lastError) ?? "none")")
        lines.append("")
        lines.append("Connection")
        lines.append("- state: \(connection.state)")
        lines.append("- host: \(nonEmpty(connection.host) ?? "none")")
        lines.append("- last_error: \(nonEmpty(connection.lastError) ?? "none")")
        lines.append("")
        appendEvents(events, to: &lines)
        appendBlock(title: "Structured Event Log", text: structuredEventLog, emptyValue: "none", to: &lines)
        appendBlock(title: "Debug Log", text: debugLog, emptyValue: "none", to: &lines)
        appendOSLog(osLogEntries, to: &lines)
        return lines.joined(separator: "\n")
    }

    private func appendEvents(_ events: [MobileDiagnosticsEvent], to lines: inout [String]) {
        lines.append("In-App Event Log")
        if events.isEmpty {
            lines.append("none")
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

    private func appendOSLog(_ entries: [MobileDiagnosticsOSLogEntry], to lines: inout [String]) {
        lines.append("Recent OSLog")
        if entries.isEmpty {
            lines.append("none")
            lines.append("")
            return
        }
        for entry in entries {
            lines.append(
                "\(format(entry.date)) \(entry.level) \(entry.subsystem)/\(entry.category): \(entry.message)"
            )
        }
        lines.append("")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
