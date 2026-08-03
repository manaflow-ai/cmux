import CmuxExtensionKit
import Foundation

enum TabsVisibleSidebarPresentation {
    static func make(
        snapshot: CmuxSidebarSnapshot?,
        errorText: String?,
        expandedWorkspaceIDs: Set<UUID>
    ) -> CmuxSidebarPresentation {
        var content: [CmuxSidebarPresentationNode] = [
            .text(String(localized: "tabsVisible.title", defaultValue: "Workspaces"), style: .heading),
        ]
        if let errorText {
            content.append(.panel(.text(errorText, style: .secondary)))
        }
        if let snapshot {
            if snapshot.workspaces.isEmpty {
                content.append(.text(
                    String(localized: "tabsVisible.noWorkspaces", defaultValue: "No workspaces shared by cmux"),
                    style: .secondary
                ))
            } else {
                content.append(contentsOf: snapshot.workspaces.map { workspaceNode(
                    $0,
                    selectedWorkspaceID: snapshot.selectedWorkspaceID,
                    isExpanded: expandedWorkspaceIDs.contains($0.id)
                ) })
            }
        } else {
            content.append(.progress)
            content.append(.text(
                String(localized: "tabsVisible.waiting", defaultValue: "Waiting for cmux"),
                style: .secondary
            ))
        }
        content.append(.spacer())
        return CmuxSidebarPresentation(
            root: .scroll(.inset(
                CmuxSidebarPresentationInsets(top: 12, leading: 10, bottom: 12, trailing: 10),
                .stack(axis: .vertical, spacing: 10, children: content)
            ))
        )
    }

    private static func workspaceNode(
        _ workspace: CmuxSidebarWorkspace,
        selectedWorkspaceID: UUID?,
        isExpanded: Bool
    ) -> CmuxSidebarPresentationNode {
        let workspaceID = workspace.id.uuidString
        let title = workspace.title.isEmpty ? workspaceID : workspace.title
        var children: [CmuxSidebarPresentationNode] = [
            .stack(axis: .horizontal, spacing: 6, children: [
                .button(CmuxSidebarPresentationButton(
                    id: "toggle:\(workspaceID)",
                    title: isExpanded ? "" : "",
                    systemImageName: isExpanded ? "chevron.down" : "chevron.right",
                    help: String(localized: "tabsVisible.toggleWorkspace", defaultValue: "Show or hide workspace tabs")
                )),
                .button(CmuxSidebarPresentationButton(
                    id: "workspace:\(workspaceID)",
                    title: title,
                    systemImageName: workspace.id == selectedWorkspaceID ? "target" : "folder"
                )),
                .text("\(workspace.surfaces.count)", style: .secondary),
            ]),
        ]
        if let detail = workspace.detail, !detail.isEmpty {
            children.append(.text(detail, style: CmuxSidebarPresentationTextStyle(
                size: 10,
                color: .secondary,
                maximumLineCount: 1
            )))
        }
        if isExpanded {
            children.append(surfacesNode(workspace))
        }
        let row = CmuxSidebarPresentationNode.stack(axis: .vertical, spacing: 4, children: children)
        return workspace.id == selectedWorkspaceID ? .panel(row) : row
    }

    private static func surfacesNode(_ workspace: CmuxSidebarWorkspace) -> CmuxSidebarPresentationNode {
        guard !workspace.surfaces.isEmpty else {
            return .inset(
                CmuxSidebarPresentationInsets(top: 0, leading: 18, bottom: 0, trailing: 0),
                .text(String(localized: "tabsVisible.noSurfaces", defaultValue: "No shared tabs"), style: .secondary)
            )
        }
        return .inset(
            CmuxSidebarPresentationInsets(top: 0, leading: 18, bottom: 0, trailing: 0),
            .stack(axis: .vertical, spacing: 3, children: workspace.surfaces.map { surface in
                .button(CmuxSidebarPresentationButton(
                    id: "surface:\(workspace.id.uuidString):\(surface.id.uuidString)",
                    title: surface.unreadCount > 0 ? "\(surface.title)  \(surface.unreadCount)" : surface.title,
                    systemImageName: iconName(for: surface.kind)
                ))
            })
        )
    }

    private static func iconName(for kind: CmuxSidebarSurfaceKind) -> String {
        switch kind {
        case .terminal:
            return "terminal"
        case .browser:
            return "globe"
        case .markdown:
            return "doc.text"
        case .filePreview:
            return "doc"
        case .rightSidebarTool:
            return "sidebar.right"
        case .project:
            return "folder"
        case .agentSession:
            return "sparkles"
        case .unknown:
            return "rectangle"
        }
    }
}
