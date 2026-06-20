import Foundation
import SwiftUI

extension VerticalTabsSidebar {
    /// The top-level workstream navigation strip rendered above the workspace
    /// list. Three states:
    /// - drilled into a workstream → a breadcrumb / back affordance;
    /// - at the top level with workstreams → a "Workstreams" header + one row
    ///   per workstream (each drills in);
    /// - no workstreams → nothing (zero regression: the sidebar is exactly the
    ///   pre-workstream flat list).
    ///
    /// This sits OUTSIDE the workspace `LazyVStack`. Its rows still receive
    /// value snapshots + closures only (no store reference crosses into the
    /// row views), matching the snapshot-boundary rule.
    @ViewBuilder
    func workstreamNavigationSection(renderContext: WorkspaceListRenderContext) -> some View {
        let fontScale = renderContext.tabItemSettings.sidebarFontScale
        if renderContext.drilledInWorkstreamId != nil {
            SidebarWorkstreamBreadcrumbView(
                workstreamName: renderContext.drilledInWorkstreamName ?? "",
                workspaceCount: renderContext.drilledInWorkstreamWorkspaceCount,
                fontScale: fontScale,
                onBack: { [weak tabManager] in tabManager?.exitWorkstreamDrillIn() }
            )
            .equatable()
            .padding(.bottom, 2)
        } else if !renderContext.workstreamRowSnapshots.isEmpty {
            VStack(alignment: .leading, spacing: tabRowSpacing) {
                Text(String(localized: "workstream.sectionHeader", defaultValue: "Workstreams"))
                    .font(.system(size: 10 * fontScale, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(renderContext.workstreamRowSnapshots) { snapshot in
                    workstreamRow(snapshot: snapshot, fontScale: fontScale)
                }
            }
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func workstreamRow(
        snapshot: SidebarWorkstreamRowSnapshot,
        fontScale: CGFloat
    ) -> some View {
        SidebarWorkstreamRowView(
            snapshot: snapshot,
            fontScale: fontScale,
            onDrillIn: { [weak tabManager, id = snapshot.id] in
                tabManager?.enterWorkstream(id: id)
            },
            onRename: { [weak tabManager, id = snapshot.id, name = snapshot.name] in
                guard let tabManager else { return }
                presentRenameWorkstreamPrompt(tabManager: tabManager, workstreamId: id, currentName: name)
            },
            onMoveUp: { [weak tabManager, id = snapshot.id] in
                guard let tabManager,
                      let index = tabManager.workstreams.firstIndex(where: { $0.id == id }) else { return }
                tabManager.moveWorkstream(id: id, toIndex: index - 1)
            },
            onMoveDown: { [weak tabManager, id = snapshot.id] in
                guard let tabManager,
                      let index = tabManager.workstreams.firstIndex(where: { $0.id == id }) else { return }
                tabManager.moveWorkstream(id: id, toIndex: index + 1)
            },
            onDelete: { [weak tabManager, id = snapshot.id, name = snapshot.name, count = snapshot.workspaceCount] in
                guard let tabManager else { return }
                guard confirmDeleteWorkstream(workstreamName: name, workspaceCount: count) else { return }
                tabManager.deleteWorkstream(id: id)
            }
        )
        .equatable()
    }
}
