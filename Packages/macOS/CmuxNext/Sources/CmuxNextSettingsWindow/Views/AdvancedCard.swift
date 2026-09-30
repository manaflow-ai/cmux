import AppKit
import CmuxNextDesign
import SwiftUI

/// Advanced: where cmux.json lives, reset, and what the last load refused.
struct AdvancedCard: View {
    let model: SettingsWindowModel
    @State private var confirmingReset = false

    var body: some View {
        let url = model.settings.file.url
        SettingsCard(title: nil) {
            InfoRow(title: SettingsWindowStrings.settingsFile, value: url.path(percentEncoded: false))
            HStack(spacing: Metrics.space4) {
                Button(SettingsWindowStrings.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(SettingsButtonStyle())
                Spacer(minLength: 0)
                Button(SettingsWindowStrings.resetAll) { confirmingReset = true }
                    .buttonStyle(SettingsButtonStyle(destructive: true))
                    .accessibilityIdentifier("cmux.settings.resetAll")
            }
            .padding(.horizontal, Metrics.space5)
            .frame(minHeight: SettingsStyle.rowHeight)
        }
        .confirmationDialog(SettingsWindowStrings.resetAllTitle, isPresented: $confirmingReset) {
            Button(SettingsWindowStrings.reset, role: .destructive) { model.resetAll() }
            Button(SettingsWindowStrings.cancel, role: .cancel) {}
        } message: {
            Text(SettingsWindowStrings.resetAllBody)
        }
        SettingsCard(title: SettingsWindowStrings.problems) {
            let problems = model.settings.diagnostics
            if problems.isEmpty {
                Text(SettingsWindowStrings.noProblems).foregroundStyle(SettingsStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: SettingsStyle.rowHeight, alignment: .leading)
                    .padding(.horizontal, Metrics.space5)
            }
            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                VStack(alignment: .leading, spacing: Metrics.space1) {
                    Text(problem.path.isEmpty ? "cmux.json" : problem.path).font(SettingsStyle.keycap)
                    Text(problem.message).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.space5)
                .padding(.vertical, Metrics.space2)
            }
        }
    }
}
