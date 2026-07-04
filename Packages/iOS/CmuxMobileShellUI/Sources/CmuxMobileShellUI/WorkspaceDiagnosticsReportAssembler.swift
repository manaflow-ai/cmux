import CmuxMobileDiagnostics
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation

#if canImport(UIKit)
struct WorkspaceDiagnosticsReportAssembler: Sendable {
    private let reportBuilder: MobileDiagnosticsReportBuilder
    private let osLogReader: any MobileDiagnosticsOSLogReading

    init(
        reportBuilder: MobileDiagnosticsReportBuilder = MobileDiagnosticsReportBuilder(),
        osLogReader: any MobileDiagnosticsOSLogReading = MobileDiagnosticsOSLogStoreReader()
    ) {
        self.reportBuilder = reportBuilder
        self.osLogReader = osLogReader
    }

    func assembleReport(
        generatedAt: Date,
        app: MobileDiagnosticsAppInfo,
        auth: MobileDiagnosticsAuthState,
        connection: MobileDiagnosticsConnectionState,
        events: [MobileDiagnosticsEvent],
        debugLog: String,
        osLogEntries: [MobileDiagnosticsOSLogEntry]
    ) -> String {
        return reportBuilder.buildReport(
            generatedAt: generatedAt,
            app: app,
            auth: auth,
            connection: connection,
            events: events,
            structuredEventLog: nil,
            debugLog: debugLog,
            osLogEntries: osLogEntries
        )
    }

    func connectionStateLabel(_ state: MobileConnectionState) -> String {
        switch state {
        case .connected:
            return L10n.string("mobile.connection.connected", defaultValue: "Connected")
        case .disconnected:
            return L10n.string("mobile.connection.unavailable", defaultValue: "Disconnected")
        }
    }

    func recentOSLogEntries(generatedAt: Date) -> [MobileDiagnosticsOSLogEntry] {
        do {
            return try osLogReader.recentEntries(
                since: generatedAt.addingTimeInterval(-15 * 60),
                limit: 120
            )
        } catch {
            return [
                MobileDiagnosticsOSLogEntry(
                    unavailableStatusAt: generatedAt,
                    message: L10n.string(
                        "mobile.diagnostics.report.osLogUnavailable",
                        defaultValue: "OSLog unavailable"
                    )
                ),
            ]
        }
    }
}
#endif
