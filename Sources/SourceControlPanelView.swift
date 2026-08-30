import AppKit
import SwiftUI

/// Read-only Source Control panel for the beta right-sidebar mode.
///
/// The first slice deliberately consumes the existing ``FileExplorerStore``
/// status snapshot. That keeps Files and Source Control on one status source
/// while the richer staged/merge model is introduced behind the same registry
/// seam in a later increment.
struct SourceControlPanelView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var fileExplorerStore: FileExplorerStore
    let onOpenDiffViewer: (String) -> Void

    init(context: RightSidebarPanelContext) {
        tabManager = context.tabManager
        fileExplorerStore = context.fileExplorerStore
        onOpenDiffViewer = context.onOpenDiffViewer
    }

    private var branchName: String? {
        guard let branch = tabManager.selectedWorkspace?.gitBranch?.branch,
              !branch.isEmpty else {
            return nil
        }
        return branch
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor.controlBackgroundColor))
        .background(
            SourceControlKeyboardFocusBridge()
                .frame(width: 1, height: 1)
        )
        .accessibilityIdentifier("RightSidebar.SourceControl")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(branchName ?? String(localized: "sourceControl.noRepository", defaultValue: "No Git repository"))
                    .font(.headline)
                    .lineLimit(1)
                if let branchName {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "sourceControl.branch.subtitle", defaultValue: "Current branch: %@"),
                            branchName
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button {
                fileExplorerStore.refreshGitStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "sourceControl.refresh.tooltip", defaultValue: "Refresh source control"))
            .accessibilityLabel(String(localized: "sourceControl.refresh.accessibilityLabel", defaultValue: "Refresh Source Control"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        let sections = fileExplorerStore.sourceControlGroups
        if fileExplorerStore.rootPath.isEmpty {
            emptyState(
                title: String(localized: "sourceControl.empty.noWorkspace.title", defaultValue: "No workspace selected"),
                detail: String(
                    localized: "sourceControl.empty.noWorkspace.detail",
                    defaultValue: "Open a workspace in a Git repository to see changes."
                )
            )
        } else if sections.isEmpty {
            emptyState(
                title: String(localized: "sourceControl.empty.clean.title", defaultValue: "No changes"),
                detail: String(localized: "sourceControl.empty.clean.detail", defaultValue: "Your working tree is clean.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(sections) { section in
                        SourceControlGroupView(
                            group: section.group,
                            resources: section.resources,
                            onOpenDiffViewer: onOpenDiffViewer
                        )
                    }
                }
                .padding(10)
            }
        }
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
