import CmuxAuthRuntime
import CmuxMobileDiagnostics
import CmuxMobileShell
import CmuxMobileShellModel
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
        let assembler = WorkspaceDiagnosticsReportAssembler()
        let (_, debugLog) = await MobileDebugLog.shared.sink.snapshotWithCount()
        // The process-wide structured `diagnosticLog` is a flight recorder created
        // once in AppCompositionRoot and never reset at the account boundary, so it is
        // deliberately omitted from this account-scoped shared report: on a shared
        // device it would otherwise let the next user surface the previous account's
        // structured activity history (connection/pairing/input/composer timing). The
        // account-scoped In-App Event Log (diagnosticsEventLog, cleared on sign-out)
        // remains the report's event source.
        let events: [MobileDiagnosticsEvent]
        if let diagnosticsEventLog = store.diagnosticsEventLog {
            events = await diagnosticsEventLog.snapshot()
        } else {
            events = []
        }
        // The `.task` driving loadReport() cancels on sheet dismissal; bail before the
        // off-main OSLog read and report assembly so their detached work is not started
        // for a report nothing will consume.
        if Task.isCancelled { return "" }
        let osLogEntries = await Task.detached(priority: .utility) {
            assembler.recentOSLogEntries(generatedAt: generatedAt)
        }.value
        if Task.isCancelled { return "" }
        let app = MobileDiagnosticsAppInfoResolver().current()
        let auth = MobileDiagnosticsAuthState(
            isSignedIn: authManager.isAuthenticated,
            lastError: authManager.lastAuthError
        )
        let connection = MobileDiagnosticsConnectionState(
            state: assembler.connectionStateLabel(store.connectionState),
            host: store.connectedHostName,
            lastError: store.lastConnectionError
        )
        return await Task.detached(priority: .utility) {
            assembler.assembleReport(
                generatedAt: generatedAt,
                app: app,
                auth: auth,
                connection: connection,
                events: events,
                debugLog: debugLog,
                osLogEntries: osLogEntries
            )
        }.value
    }

    @MainActor
    private func copy(_ report: String) {
        UIPasteboard.general.string = report
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
#endif
