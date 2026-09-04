import AppKit
import SwiftUI

/// Read-only Source Control panel for the beta right-sidebar mode.
///
/// The first slice deliberately consumes the existing ``FileExplorerStore``
/// status snapshot. That keeps Files and Source Control on one status source
/// while the richer staged/merge model is introduced behind the same registry
/// seam in a later increment.
struct SourceControlPanelView: View {
    let tabManager: TabManager
    /// The parent right-sidebar view owns observation of this store and passes
    /// the immutable status projection through the panel context.
    let fileExplorerStore: FileExplorerStore
    let onOpenDiffViewer: (String, GitFileDiffSource) -> Void
    @FocusState private var focusedResourceID: String?

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

    private var isRemoteWorkspace: Bool {
        tabManager.selectedWorkspace?.isRemoteWorkspace == true
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
            SourceControlKeyboardFocusBridge(
                focusFirstItem: focusFirstSourceControlResource
            )
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
        VStack(spacing: 0) {
            if isRemoteWorkspace {
                Text(String(
                    localized: "sourceControl.remoteDiffUnavailable",
                    defaultValue: "Diff previews are unavailable for SSH workspaces."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: NSColor.separatorColor).opacity(0.12))
            }
            contentBody
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        let sections = fileExplorerStore.sourceControlGroups
        if fileExplorerStore.rootPath.isEmpty {
            emptyState(
                title: String(localized: "sourceControl.empty.noWorkspace.title", defaultValue: "No workspace selected"),
                detail: String(
                    localized: "sourceControl.empty.noWorkspace.detail",
                    defaultValue: "Open a workspace in a Git repository to see changes."
                )
            )
        } else if fileExplorerStore.gitStatusLoadState == .loading || fileExplorerStore.gitStatusLoadState == .idle {
            statusLoadingState
        } else if fileExplorerStore.gitStatusLoadState == .unavailable {
            statusUnavailableState
        } else if sections.isEmpty {
            emptyState(
                title: String(localized: "sourceControl.empty.clean.title", defaultValue: "No changes"),
                detail: String(localized: "sourceControl.empty.clean.detail", defaultValue: "Your working tree is clean.")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(sections) { section in
                            SourceControlGroupView(
                                group: section.group,
                                resources: section.resources,
                                onOpenDiffViewer: onOpenDiffViewer,
                                focusedResourceID: $focusedResourceID,
                                isDiffAvailable: !isRemoteWorkspace
                            )
                        }
                    }
                    .padding(10)
                }
                .onChange(of: focusedResourceID) { _, resourceID in
                    guard let resourceID else { return }
                    proxy.scrollTo(resourceID, anchor: .center)
                }
            }
        }
    }

    private var statusLoadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(
                localized: "sourceControl.status.loading",
                defaultValue: "Checking Git status…"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var statusUnavailableState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(String(
                localized: "sourceControl.status.unavailable.title",
                defaultValue: "Source Control unavailable"
            ))
            .font(.headline)
            Text(String(
                localized: "sourceControl.status.unavailable.detail",
                defaultValue: "Git status could not be read for this workspace."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @MainActor
    private func focusFirstSourceControlResource() -> Bool {
        guard !isRemoteWorkspace else { return false }
        guard let resourceID = fileExplorerStore.sourceControlGroups
            .first?.resources.first?.id else {
            return false
        }
        focusedResourceID = resourceID
        return true
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
