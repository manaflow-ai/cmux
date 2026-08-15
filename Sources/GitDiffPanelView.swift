import AppKit
import CmuxGit
import CmuxSidebarGit
import SwiftUI

/// The Git right-sidebar panel: a changed-file list with an inline diff.
///
/// Backed by ``GitDiffPanelViewModel``. The view reads the model's state in
/// `body` and passes only immutable value ``GitDiffPanelSnapshot``s into the
/// `LazyVStack`/`ForEach` row subviews (never the observable model), and no
/// `body`-called function writes model state — honoring the SwiftUI
/// list-boundary rule.
struct GitDiffPanelView: View {
    let tabManager: TabManager
    let workspaceId: UUID?
    let isVisible: Bool

    @State private var viewModel: GitDiffPanelViewModel
    @State private var resolvedDirectory: String?

    init(tabManager: TabManager, workspaceId: UUID?, isVisible: Bool) {
        self.tabManager = tabManager
        self.workspaceId = workspaceId
        self.isVisible = isVisible
        let metadataService = tabManager.sidebarGitMetadataService
        _viewModel = State(initialValue: GitDiffPanelViewModel(
            invalidationStreamFactory: { metadataService.diffInvalidations() }
        ))
    }

    var body: some View {
        content
            .onAppear {
                viewModel.isVisible = isVisible
                refreshDirectory()
            }
            .onDisappear {
                viewModel.isVisible = false
                unregisterDemand()
                viewModel.cancelInFlight()
            }
            .onChange(of: isVisible) { _, visible in
                viewModel.isVisible = visible
                if visible {
                    refreshDirectory()
                }
            }
            .onChange(of: workspaceId) { _, _ in
                refreshDirectory()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let message):
            emptyState(message)
        case .error(let message, let retry):
            errorState(message: message, retry: retry)
        case .loaded(let snapshot):
            loadedView(snapshot)
        }
    }

    private func loadedView(_ snapshot: GitDiffPanelSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GitDiffHeaderView(files: snapshot.files)
            Divider()
            if snapshot.files.files.isEmpty {
                emptyState(String(localized: "gitDiff.panel.noChanges", defaultValue: "No changes"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot.files.files, id: \.path) { file in
                            GitDiffFileRow(
                                file: file,
                                isSelected: file.path == snapshot.selectedPath
                            ) {
                                viewModel.selectFile(file.path)
                            }
                            Divider()
                        }
                        if snapshot.files.truncated {
                            noteText(String(
                                localized: "gitDiff.panel.firstFiles",
                                defaultValue: "showing first 500 files"
                            ))
                        }
                    }
                }
                if snapshot.selectedPath != nil, snapshot.selectedDiff != nil {
                    Divider()
                    GitDiffDetailView(snapshot: snapshot)
                }
            }
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    private func errorState(message: String, retry: Bool) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if retry {
                Button {
                    viewModel.refresh()
                } label: {
                    Text(String(localized: "gitDiff.panel.retry", defaultValue: "Retry"))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    private func refreshDirectory() {
        guard viewModel.isVisible else { return }
        guard let workspace = workspace(for: workspaceId) else {
            viewModel.setDirectory(nil)
            return
        }
        let directory = WorkspaceGitDiffDirectoryResolver().resolvedDirectory(
            for: workspace,
            focusedPanelId: workspace.focusedPanelId
        )
        if directory != resolvedDirectory {
            if let old = resolvedDirectory {
                unregisterDemand(for: old)
            }
            resolvedDirectory = directory
            if let directory {
                tabManager.sidebarGitMetadataService.registerGitDiffDemand(for: directory)
            }
        }
        viewModel.setDirectory(directory)
    }

    private func unregisterDemand() {
        if let resolvedDirectory {
            unregisterDemand(for: resolvedDirectory)
        }
    }

    private func unregisterDemand(for directory: String) {
        tabManager.sidebarGitMetadataService.unregisterGitDiffDemand(for: directory)
    }

    private func workspace(for workspaceId: UUID?) -> Workspace? {
        guard let workspaceId else { return nil }
        return tabManager.tabs.first(where: { $0.id == workspaceId })
    }
}

/// The panel header: branch and the comparison base.
private struct GitDiffHeaderView: View {
    let files: WorkspaceChangedFiles

    var body: some View {
        let baseLabel = baseLabelText
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let branch = files.branch, !branch.isEmpty {
                Text(branch)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.headline)
            }
            Text(baseLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var baseLabelText: String {
        if files.comparisonBase == .mergeBase, let baseRef = files.baseRef, !baseRef.isEmpty {
            return String(format: String(localized: "gitDiff.header.vsBase", defaultValue: "vs %@"), baseRef)
        }
        return String(format: String(localized: "gitDiff.header.uncommitted", defaultValue: "uncommitted on %@"), files.branch ?? "")
    }
}

/// One changed file: status badge, path, and line counts.
private struct GitDiffFileRow: View {
    let file: WorkspaceChangedFile
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Text(statusLetter)
                    .font(.caption.monospaced())
                    .foregroundStyle(statusColor)
                    .frame(width: 14)
                Text(file.path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                Spacer(minLength: 4)
                Text(lineSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("gitDiffFileRow.\(file.path)")
    }

    private var statusLetter: String {
        switch file.status {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        }
    }

    private var statusColor: Color {
        switch file.status {
        case .added: return .green
        case .modified: return .yellow
        case .deleted: return .red
        case .renamed: return .purple
        case .untracked: return .gray
        }
    }

    private var lineSummary: String {
        if file.isBinary {
            return String(localized: "gitDiff.file.binary", defaultValue: "Binary")
        }
        return "+\(file.additions) −\(file.deletions)"
    }
}

/// The selected file's inline diff.
private struct GitDiffDetailView: View {
    let snapshot: GitDiffPanelSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let diff = snapshot.selectedDiff, diff.isBinary {
                noteText(String(localized: "gitDiff.diff.binary", defaultValue: "Binary file"))
            } else if let diff = snapshot.selectedDiff, diff.truncated {
                noteText(String(localized: "gitDiff.diff.truncated", defaultValue: "diff truncated"))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshot.diffRows) { row in
                        GitDiffRowView(row: row)
                    }
                }
            }
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

/// One rendered unified-diff line, colored by kind.
private struct GitDiffRowView: View {
    let row: GitDiffRow

    var body: some View {
        Text(row.text.isEmpty ? " " : row.text)
            .font(.body.monospaced())
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 0.5)
            .background(backgroundColor)
    }

    private var foregroundColor: Color {
        switch row.kind {
        case .addition: return .green
        case .deletion: return .red
        case .hunk: return .blue
        case .header, .noNewline: return .secondary
        case .context: return .primary
        }
    }

    private var backgroundColor: Color {
        switch row.kind {
        case .addition: return Color.green.opacity(0.06)
        case .deletion: return Color.red.opacity(0.06)
        default: return Color.clear
        }
    }
}
