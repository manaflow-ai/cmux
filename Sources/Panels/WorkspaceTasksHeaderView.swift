import SwiftUI

struct WorkspaceTasksHeaderView: View {
    let openCount: Int
    let archivedCount: Int
    let showsOpenAsTabButton: Bool
    let openSurface: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(localized: "workspaceTasks.surface.title", defaultValue: "Workspace Tasks"))
                    .cmuxFont(size: 18, weight: .semibold)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if showsOpenAsTabButton {
                    Button(action: openSurface) {
                        CmuxSystemSymbolImage(magnified: "macwindow.badge.plus", pointSize: 13)
                            .frame(width: 28, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.34), lineWidth: 1)
                    }
                    .help(String(localized: "workspaceTasks.openAsTab.help", defaultValue: "Open as tab"))
                    .accessibilityLabel(String(localized: "workspaceTasks.openAsTab.label", defaultValue: "Open Workspace Tasks as Tab"))
                }
            }

            HStack(spacing: 7) {
                Circle()
                    .fill(taskAccent.opacity(0.92))
                    .frame(width: 6, height: 6)
                Text(summary)
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        String(
            format: String(localized: "workspaceTasks.summary", defaultValue: "%d open, %d archived"),
            locale: .current,
            openCount,
            archivedCount
        )
    }

    private var taskAccent: Color {
        Color(red: 0.86, green: 0.25, blue: 0.19)
    }
}
