import SwiftUI

struct WorkspaceTasksDisabledView: View {
    var body: some View {
        VStack(spacing: 10) {
            CmuxSystemSymbolImage(magnified: "checklist", pointSize: 18)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "workspaceTasks.disabled.title", defaultValue: "Workspace Tasks is disabled"))
                .cmuxFont(size: 14, weight: .semibold)
            Text(String(
                localized: "workspaceTasks.disabled.detail",
                defaultValue: "Enable Workspace Tasks in Beta Features to manage this list."
            ))
            .cmuxFont(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
