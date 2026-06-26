import CmuxAuthRuntime
import CmuxMobileDiagnostics
import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import SwiftUI
#if canImport(UIKit)
@preconcurrency import UIKit
#endif

#if canImport(UIKit)
struct WorkspaceDiagnosticsSheet: View {
    let store: CMUXMobileShellStore
    let authManager: AuthCoordinator
    let close: () -> Void

    @State private var reportText: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L10n.string("mobile.diagnostics.share", defaultValue: "Share Diagnostics"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("mobile.diagnostics.close", defaultValue: "Close")) {
                            close()
                        }
                    }
                    if let reportText {
                        ToolbarItemGroup(placement: .confirmationAction) {
                            Button(action: { copy(reportText) }) {
                                Label(
                                    L10n.string("mobile.diagnostics.copy", defaultValue: "Copy"),
                                    systemImage: "doc.on.clipboard"
                                )
                            }
                            .accessibilityIdentifier("MobileCopyDiagnosticsButton")
                            ShareLink(item: reportText) {
                                Label(
                                    L10n.string("mobile.diagnostics.shareAction", defaultValue: "Share"),
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                            .accessibilityIdentifier("MobileShareDiagnosticsButton")
                        }
                    }
                }
        }
        .presentationDetents([.large])
        .task {
            await loadReport()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let reportText {
            ScrollView {
                Text(reportText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .accessibilityIdentifier("MobileDiagnosticsReportText")
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @MainActor
    private func loadReport() async {
        guard !isLoading, reportText == nil else { return }
        isLoading = true
        reportText = await buildReport()
        isLoading = false
    }

    @MainActor
    private func buildReport() async -> String {
        let generatedAt = Date()
        let debugLogSnapshot = await MobileDebugLog.shared.sink.snapshotWithCount()
        let structuredEventLogText: String?
        if let diagnosticLog = store.diagnosticLog {
            let data = await diagnosticLog.export()
            structuredEventLogText = data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
        } else {
            structuredEventLogText = nil
        }
        let events: [MobileDiagnosticsEvent]
        if let diagnosticsEventLog = store.diagnosticsEventLog {
            events = await diagnosticsEventLog.snapshot()
        } else {
            events = []
        }
        let osLogEntries = await Task.detached(priority: .utility) {
            Self.recentOSLogEntries(generatedAt: generatedAt)
        }.value
        return MobileDiagnosticsReportBuilder().buildReport(
            generatedAt: generatedAt,
            app: MobileDiagnosticsAppInfo.current(),
            auth: MobileDiagnosticsAuthState(
                isSignedIn: authManager.isAuthenticated,
                lastError: authManager.lastAuthError
            ),
            connection: MobileDiagnosticsConnectionState(
                state: String(describing: store.connectionState),
                host: store.connectedHostName,
                lastError: store.lastConnectionError ?? store.connectionError
            ),
            events: events,
            structuredEventLog: structuredEventLogText,
            debugLog: debugLogSnapshot.body,
            osLogEntries: osLogEntries
        )
    }

    private static func recentOSLogEntries(generatedAt: Date) -> [MobileDiagnosticsOSLogEntry] {
        do {
            return try MobileDiagnosticsOSLogStoreReader().recentEntries(
                since: generatedAt.addingTimeInterval(-15 * 60),
                limit: 120
            )
        } catch {
            return [
                MobileDiagnosticsOSLogEntry(
                    date: generatedAt,
                    subsystem: "cmux",
                    category: "diagnostics",
                    level: "error",
                    message: "OSLog unavailable: \(String(describing: type(of: error)))"
                ),
            ]
        }
    }

    @MainActor
    private func copy(_ report: String) {
        UIPasteboard.general.string = report
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
#endif
