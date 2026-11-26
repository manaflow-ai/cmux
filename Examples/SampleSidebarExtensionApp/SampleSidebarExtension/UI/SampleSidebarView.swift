import SwiftUI

struct SampleSidebarView: View {
    var model: SidebarConnectionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let insights = model.insights {
                    header(insights)
                    if let errorText = model.errorText {
                        statusBanner(errorText)
                    } else if !insights.canSelectWorkspace {
                        statusBanner(String(localized: "sampleSidebar.selectionLimited", defaultValue: "Review access in cmux to enable selecting workspaces from this extension."))
                    }
                    actionBar(insights)
                    workspaceList(insights)
                    Divider()
                    signalSummary(insights)
                } else {
                    waitingState
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ insights: SidebarInsightModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "sampleSidebar.title", defaultValue: "Workspace Signals"))
                .font(.system(size: 14, weight: .semibold))
            Text(String.localizedStringWithFormat(
                String(localized: "sampleSidebar.workspaceCount", defaultValue: "%d workspaces shared by cmux"),
                insights.totalCount
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                SummaryPill(value: "\(insights.totalCount)", label: String(localized: "sampleSidebar.workspaces", defaultValue: "Workspaces"))
                SummaryPill(value: "\(insights.unreadCount)", label: String(localized: "sampleSidebar.unread", defaultValue: "Unread"))
                SummaryPill(value: "\(insights.pinnedCount)", label: String(localized: "sampleSidebar.pinned", defaultValue: "Pinned"))
            }
        }
    }

    private func statusBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func actionBar(_ insights: SidebarInsightModel) -> some View {
        HStack(spacing: 6) {
            Button {
                Task { @MainActor in await model.selectPreviousWorkspace() }
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 18, height: 18)
            }
            .disabled(!insights.canNavigateWorkspace)
            .help(String(localized: "sampleSidebar.previousWorkspace", defaultValue: "Previous workspace"))

            Button {
                Task { @MainActor in await model.selectNextWorkspace() }
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 18, height: 18)
            }
            .disabled(!insights.canNavigateWorkspace)
            .help(String(localized: "sampleSidebar.nextWorkspace", defaultValue: "Next workspace"))

            Divider()
                .frame(height: 18)

            Button {
                Task { @MainActor in await model.selectPreviousSurface() }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 18, height: 18)
            }
            .disabled(!insights.canNavigateSurface)
            .help(String(localized: "sampleSidebar.previousSurface", defaultValue: "Previous surface"))

            Button {
                Task { @MainActor in await model.selectNextSurface() }
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 18, height: 18)
            }
            .disabled(!insights.canNavigateSurface)
            .help(String(localized: "sampleSidebar.nextSurface", defaultValue: "Next surface"))

            Button {
                Task { @MainActor in await model.createTerminalSurface(in: insights.selectedWorkspace?.id) }
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .frame(width: 18, height: 18)
            }
            .disabled(!insights.canCreateSurface)
            .help(String(localized: "sampleSidebar.newTerminalSurface", defaultValue: "New terminal surface"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func workspaceList(_ insights: SidebarInsightModel) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(localized: "sampleSidebar.allWorkspaces", defaultValue: "All Workspaces"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if !insights.hasWorkspaceMetadata {
                Text(String(localized: "sampleSidebar.metadataLimited", defaultValue: "Workspace metadata has not been shared yet. Review access in cmux to show workspace rows."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if insights.allWorkspaces.isEmpty {
                Text(String(localized: "sampleSidebar.noWorkspaces", defaultValue: "No workspaces were shared by cmux."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(insights.allWorkspaces) { insight in
                    WorkspaceInsightRow(
                        insight: insight,
                        action: {
                            Task { @MainActor in await model.selectWorkspace(insight.id) }
                        },
                        surfaceAction: { surfaceID in
                            Task { @MainActor in await model.selectSurface(workspaceID: insight.id, surfaceID: surfaceID) }
                        }
                    )
                }
            }
        }
    }

    private func signalSummary(_ insights: SidebarInsightModel) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(localized: "sampleSidebar.focusQueue", defaultValue: "Focus Queue"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if insights.focusQueue.isEmpty {
                Text(String(localized: "sampleSidebar.noSignals", defaultValue: "No active workspace signals beyond the selected workspace"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text(signalSummaryText(insights.focusQueue))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func signalSummaryText(_ insights: [WorkspaceInsight]) -> String {
        let names = insights.prefix(3).map(\.title).joined(separator: ", ")
        if insights.count <= 3 {
            return String.localizedStringWithFormat(
                String(localized: "sampleSidebar.signalSummary", defaultValue: "Signals in %@"),
                names
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "sampleSidebar.signalSummaryMore", defaultValue: "Signals in %@ and %d more"),
            names,
            insights.count - 3
        )
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
