import CmuxFoundation
import SwiftUI

/// Project Worktrees section backed directly by Git rather than provider rows.
struct WorktreeSidebarSectionView: View {
    let sectionID: String
    let title: String
    let isCollapsed: Bool
    let onToggleCollapsed: @MainActor () -> Void
    @State private var model: WorktreeSidebarModel

    init(
        sectionID: String,
        title: String,
        projectRootPath: String,
        isCollapsed: Bool,
        onToggleCollapsed: @escaping @MainActor () -> Void,
        workspaceController: WorktreeSidebarWorkspaceController
    ) {
        self.sectionID = sectionID
        self.title = title
        self.isCollapsed = isCollapsed
        self.onToggleCollapsed = onToggleCollapsed
        _model = State(initialValue: WorktreeSidebarModel(
            projectRootPath: projectRootPath,
            workspaces: workspaceController
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Button(action: onToggleCollapsed) {
                    Image(systemName: isCollapsed ? "folder" : "folder.fill")
                        .cmuxFont(size: 13, weight: .regular)
                        .offset(y: -0.5)
                }
                .buttonStyle(.plain)
                .safeHelp(String(
                    localized: "sidebar.extension.toggleSection",
                    defaultValue: "Toggle section"
                ))

                Text(title)
                    .cmuxFont(size: 12, weight: .regular)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if model.listingPhase == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .cmuxFont(size: 9, weight: .semibold)
                        .foregroundStyle(.orange)
                        .safeHelp(refreshFailureHelp)
                }

                if model.isRefreshing || model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .frame(width: 16, height: 16)
                }

                Button {
                    model.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .cmuxFont(size: 10, weight: .regular)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(model.isRefreshing)
                .safeHelp(String(
                    localized: "worktreeSidebar.refresh",
                    defaultValue: "Refresh worktrees"
                ))
                .accessibilityIdentifier("WorktreeSidebarRefreshButton.\(sectionID)")

                Button {
                    model.createWorktree()
                } label: {
                    Image(systemName: "plus")
                        .cmuxFont(size: 11, weight: .regular)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .safeHelp(String(
                    localized: "sidebar.extension.createWorktree",
                    defaultValue: "Create worktree"
                ))
                .accessibilityIdentifier("ExtensionSidebarCreateWorktreeButton.\(sectionID)")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if !isCollapsed {
                WorktreeSidebarListView(
                    rows: model.rows,
                    isInitialLoading: model.isInitialLoading,
                    errorDetails: model.listingPhase == .failed
                        ? (model.listingErrorDetails ?? "")
                        : nil,
                    actions: WorktreeSidebarRowActions.bound(to: model)
                )
                .clipped()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var refreshFailureHelp: String {
        let message = String(
            localized: "worktreeSidebar.refreshFailed.help",
            defaultValue: "Worktree refresh failed. The rows may be out of date."
        )
        guard let details = model.listingErrorDetails, !details.isEmpty else { return message }
        return message + "\n\n" + details
    }
}
