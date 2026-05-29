import SwiftUI

struct SampleSidebarView: View {
    var model: SidebarConnectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let insights = model.insights {
                header(insights)
                if let selected = insights.selectedWorkspace {
                    WorkspaceInsightRow(
                        insight: selected,
                        action: { model.selectWorkspace(selected.id) }
                    )
                }
                Divider()
                focusQueue(insights)
            } else {
                waitingState
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ insights: SidebarInsightModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "sampleSidebar.title", defaultValue: "Workspace Signals"))
                .font(.system(size: 14, weight: .semibold))
            HStack(spacing: 6) {
                SummaryPill(value: "\(insights.unreadCount)", label: String(localized: "sampleSidebar.unread", defaultValue: "Unread"))
                SummaryPill(value: "\(insights.portCount)", label: String(localized: "sampleSidebar.ports", defaultValue: "Ports"))
                SummaryPill(value: "\(insights.pullRequestCount)", label: String(localized: "sampleSidebar.prs", defaultValue: "PRs"))
            }
        }
    }

    private func focusQueue(_ insights: SidebarInsightModel) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(localized: "sampleSidebar.focusQueue", defaultValue: "Focus Queue"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if insights.focusQueue.isEmpty {
                Text(String(localized: "sampleSidebar.noSignals", defaultValue: "No active workspace signals"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(insights.focusQueue.prefix(8)) { insight in
                    WorkspaceInsightRow(
                        insight: insight,
                        action: { model.selectWorkspace(insight.id) }
                    )
                }
            }
        }
    }

    private var waitingState: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(model.errorText ?? String(localized: "sampleSidebar.waitingForHost", defaultValue: "Waiting for cmux"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "sampleSidebar.refresh", defaultValue: "Refresh")) {
                model.refreshSnapshot()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .medium))
        }
    }
}
