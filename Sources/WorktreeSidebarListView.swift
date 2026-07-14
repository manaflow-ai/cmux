import CmuxFoundation
import SwiftUI

/// Lazy row subtree containing only immutable snapshots and action closures.
struct WorktreeSidebarListView: View {
    let rows: [WorktreeSidebarRow]
    let isInitialLoading: Bool
    let errorDetails: String?
    let actions: WorktreeSidebarRowActions

    var body: some View {
        if isInitialLoading {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(String(
                    localized: "worktreeSidebar.loading",
                    defaultValue: "Loading worktrees…"
                ))
                    .cmuxFont(size: 11, weight: .regular)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
        } else if rows.isEmpty, let errorDetails {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(
                    localized: "worktreeSidebar.loadError",
                    defaultValue: "Couldn’t load worktrees"
                ))
                    .cmuxFont(size: 11, weight: .medium)
                if !errorDetails.isEmpty {
                    Text(errorDetails)
                        .cmuxFont(size: 10, weight: .regular)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
        } else if rows.isEmpty {
            Text(String(
                localized: "worktreeSidebar.empty",
                defaultValue: "Git reports no worktrees."
            ))
                .cmuxFont(size: 11, weight: .regular)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
        } else {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(rows) { row in
                    WorktreeSidebarRowView(row: row, actions: actions)
                        .equatable()
                        .onAppear { actions.becameVisible(row) }
                        .onDisappear { actions.becameHidden(row) }
                        .accessibilityIdentifier("worktreeSidebar.row.\(row.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
