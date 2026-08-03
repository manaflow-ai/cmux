import CmuxExtensionKit

@MainActor
enum SampleSidebarPresentation {
    static func make(model: SidebarConnectionModel) -> CmuxSidebarPresentation {
        var content: [CmuxSidebarPresentationNode]
        if let insights = model.insights {
            content = header(insights)
            if let errorText = model.errorText {
                content.append(.panel(.text(errorText, style: .secondary)))
            } else if !insights.canSelectWorkspace {
                content.append(.panel(.text(
                    String(localized: "sampleSidebar.selectionLimited", defaultValue: "Review access in cmux to enable selecting workspaces from this extension."),
                    style: .secondary
                )))
            }
            content.append(actionBar(insights))
            content.append(workspaceList(insights))
            content.append(.divider)
            content.append(signalSummary(insights))
        } else {
            content = waitingState(errorText: model.errorText)
        }
        content.append(.spacer())
        return CmuxSidebarPresentation(
            root: .scroll(.inset(
                CmuxSidebarPresentationInsets(top: 14, leading: 12, bottom: 14, trailing: 12),
                .stack(axis: .vertical, spacing: 12, children: content)
            ))
        )
    }

    private static func header(_ insights: SidebarInsightModel) -> [CmuxSidebarPresentationNode] {
        [
            .text(String(localized: "sampleSidebar.title", defaultValue: "Workspace Signals"), style: .heading),
            .text(String.localizedStringWithFormat(
                String(localized: "sampleSidebar.workspaceCount", defaultValue: "%d workspaces shared by cmux"),
                insights.totalCount
            ), style: .secondary),
            .stack(axis: .horizontal, spacing: 6, children: [
                SummaryPill.node(value: "\(insights.totalCount)", label: String(localized: "sampleSidebar.workspaces", defaultValue: "Workspaces")),
                SummaryPill.node(value: "\(insights.unreadCount)", label: String(localized: "sampleSidebar.unread", defaultValue: "Unread")),
                SummaryPill.node(value: "\(insights.pinnedCount)", label: String(localized: "sampleSidebar.pinned", defaultValue: "Pinned")),
            ]),
        ]
    }

    private static func actionBar(_ insights: SidebarInsightModel) -> CmuxSidebarPresentationNode {
        .stack(axis: .horizontal, spacing: 6, children: [
            actionButton("previous-workspace", "chevron.up", insights.canNavigateWorkspace, String(localized: "sampleSidebar.previousWorkspace", defaultValue: "Previous workspace")),
            actionButton("next-workspace", "chevron.down", insights.canNavigateWorkspace, String(localized: "sampleSidebar.nextWorkspace", defaultValue: "Next workspace")),
            .divider,
            actionButton("previous-surface", "chevron.left", insights.canNavigateSurface, String(localized: "sampleSidebar.previousSurface", defaultValue: "Previous surface")),
            actionButton("next-surface", "chevron.right", insights.canNavigateSurface, String(localized: "sampleSidebar.nextSurface", defaultValue: "Next surface")),
            actionButton(
                "create-surface:\(insights.selectedWorkspace?.id.uuidString ?? "")",
                "plus.rectangle.on.rectangle",
                insights.canCreateSurface,
                String(localized: "sampleSidebar.newTerminalSurface", defaultValue: "New terminal surface")
            ),
        ])
    }

    private static func actionButton(
        _ id: String,
        _ symbol: String,
        _ isEnabled: Bool,
        _ help: String
    ) -> CmuxSidebarPresentationNode {
        .button(CmuxSidebarPresentationButton(
            id: id,
            title: "",
            systemImageName: symbol,
            isEnabled: isEnabled,
            help: help
        ))
    }

    private static func workspaceList(_ insights: SidebarInsightModel) -> CmuxSidebarPresentationNode {
        var rows: [CmuxSidebarPresentationNode] = [
            .text(String(localized: "sampleSidebar.allWorkspaces", defaultValue: "All Workspaces"), style: .secondary),
        ]
        if !insights.hasWorkspaceMetadata {
            rows.append(.text(
                String(localized: "sampleSidebar.metadataLimited", defaultValue: "Workspace metadata has not been shared yet. Review access in cmux to show workspace rows."),
                style: .secondary
            ))
        } else if insights.allWorkspaces.isEmpty {
            rows.append(.text(
                String(localized: "sampleSidebar.noWorkspaces", defaultValue: "No workspaces were shared by cmux."),
                style: .secondary
            ))
        } else {
            rows.append(contentsOf: insights.allWorkspaces.map(WorkspaceInsightRow.node))
        }
        return .stack(axis: .vertical, spacing: 7, children: rows)
    }

    private static func signalSummary(_ insights: SidebarInsightModel) -> CmuxSidebarPresentationNode {
        let detail: String
        if insights.focusQueue.isEmpty {
            detail = String(localized: "sampleSidebar.noSignals", defaultValue: "No active workspace signals beyond the selected workspace")
        } else {
            detail = signalSummaryText(insights.focusQueue)
        }
        return .stack(axis: .vertical, spacing: 7, children: [
            .text(String(localized: "sampleSidebar.focusQueue", defaultValue: "Focus Queue"), style: .secondary),
            .text(detail, style: .secondary),
        ])
    }

    private static func signalSummaryText(_ insights: [WorkspaceInsight]) -> String {
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

    private static func waitingState(errorText: String?) -> [CmuxSidebarPresentationNode] {
        [
            .progress,
            .text(
                errorText ?? String(localized: "sampleSidebar.waitingForHost", defaultValue: "Waiting for cmux"),
                style: .secondary
            ),
            .button(CmuxSidebarPresentationButton(
                id: "refresh",
                title: String(localized: "sampleSidebar.refresh", defaultValue: "Refresh"),
                systemImageName: "arrow.clockwise"
            )),
        ]
    }
}
