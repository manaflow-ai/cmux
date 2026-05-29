import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

struct SurfaceResumeApprovalSettingsCard: View {
    @State private var recordCount = 0

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("terminal.resumeCommands"),
                String(localized: "settings.terminal.resumeCommands", defaultValue: "Resume Commands"),
                subtitle: String(
                    localized: "settings.terminal.resumeCommands.subtitle",
                    defaultValue: "Review signed command prefixes that can restore non-agent terminal surfaces."
                ),
                controlWidth: 170,
                searchAnchorID: SettingsSearchIndex.settingID(for: .terminal, idSuffix: "resume-commands")
            ) {
                HStack(spacing: 8) {
                    Text(String(format: "%d", recordCount))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)

                    Button(String(localized: "settings.settingsJSON.openButton", defaultValue: "Open")) {
                        openCmuxSettingsFileInEditor()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: SurfaceResumeApprovalStore.didChangeNotification)) { _ in
            reload()
        }
    }

    private func reload() {
        recordCount = SurfaceResumeApprovalStore.loadRecords().count
    }
}
