import AppKit
import SwiftUI

extension RightSidebarMode {
    static let sourceControl = Self("sourceControl")
}

/// Read-only Source Control panel for the beta right-sidebar mode.
///
/// The first slice deliberately consumes the existing ``FileExplorerStore``
/// status snapshot. That keeps Files and Source Control on one status source
/// while the richer staged/merge model is introduced behind the same registry
/// seam in a later increment.
struct SourceControlPanelView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var fileExplorerStore: FileExplorerStore
    let onOpenDiffViewer: () -> Void

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

    private var rows: [SourceControlResourceRow] {
        let root = fileExplorerStore.rootPath
        return fileExplorerStore.gitStatusByPath
            .compactMap { path, status in
                guard !Self.isDirectory(path) else { return nil }
                let relativePath = Self.relativePath(path, root: root)
                return SourceControlResourceRow(path: path, relativePath: relativePath, status: status)
            }
            .sorted { lhs, rhs in
                if lhs.groupOrder != rhs.groupOrder { return lhs.groupOrder < rhs.groupOrder }
                return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
    }

    private var groups: [SourceControlGroupSection] {
        SourceControlGroup.allCases.compactMap { group in
            let grouped = rows.filter { $0.group == group }
            return grouped.isEmpty ? nil : SourceControlGroupSection(group: group, resources: grouped)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor.controlBackgroundColor))
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
        if fileExplorerStore.rootPath.isEmpty {
            emptyState(
                title: String(localized: "sourceControl.empty.noWorkspace.title", defaultValue: "No workspace selected"),
                detail: String(
                    localized: "sourceControl.empty.noWorkspace.detail",
                    defaultValue: "Open a workspace in a Git repository to see changes."
                )
            )
        } else if groups.isEmpty {
            emptyState(
                title: String(localized: "sourceControl.empty.clean.title", defaultValue: "No changes"),
                detail: String(localized: "sourceControl.empty.clean.detail", defaultValue: "Your working tree is clean.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { section in
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

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    private static func relativePath(_ path: String, root: String) -> String {
        guard !root.isEmpty else { return path }
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path.hasPrefix(normalizedRoot + "/") else { return path }
        return String(path.dropFirst(normalizedRoot.count + 1))
    }
}

private enum SourceControlGroup: String, CaseIterable, Hashable {
    case merge
    case staged
    case changes
    case untracked

    var title: String {
        switch self {
        case .merge:
            return String(localized: "sourceControl.group.merge", defaultValue: "Merge Changes")
        case .staged:
            return String(localized: "sourceControl.group.staged", defaultValue: "Staged Changes")
        case .changes:
            return String(localized: "sourceControl.group.changes", defaultValue: "Changes")
        case .untracked:
            return String(localized: "sourceControl.group.untracked", defaultValue: "Untracked Changes")
        }
    }
}

private struct SourceControlResourceRow: Identifiable, Hashable {
    let path: String
    let relativePath: String
    let status: GitFileStatus

    var id: String { path }

    var group: SourceControlGroup {
        status == .untracked ? .untracked : .changes
    }

    var groupOrder: Int {
        switch group {
        case .merge: return 0
        case .staged: return 1
        case .changes: return 2
        case .untracked: return 3
        }
    }

    var statusLetter: String {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        }
    }
}

private struct SourceControlGroupSection: Identifiable {
    let group: SourceControlGroup
    let resources: [SourceControlResourceRow]

    var id: SourceControlGroup { group }
}

private struct SourceControlGroupView: View {
    let group: SourceControlGroup
    let resources: [SourceControlResourceRow]
    let onOpenDiffViewer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                Text(String(resources.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            ForEach(resources) { resource in
                Button {
                    onOpenDiffViewer()
                } label: {
                    HStack(spacing: 8) {
                        Text(resource.statusLetter)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(
                                resource.status == .untracked ? Color.secondary : Color.orange
                            )
                            .frame(width: 14)
                        Text(resource.relativePath)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
                .accessibilityLabel(
                    String.localizedStringWithFormat(
                        String(localized: "sourceControl.resource.accessibilityLabel", defaultValue: "%@, %@"),
                        resource.relativePath,
                        resource.statusLetter
                    )
                )
            }
        }
    }
}
