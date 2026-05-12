import SwiftUI

struct DiffReviewPanelView: View {
    @ObservedObject var store: DiffReviewStore
    let directory: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content
        }
        .onAppear {
            store.setDirectory(directory)
        }
        .onChange(of: directory) { _, nextDirectory in
            store.setDirectory(nextDirectory)
        }
        .onDisappear {
            store.stopLiveRefresh()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Picker(
                selection: Binding(
                    get: { store.selectedTargetID },
                    set: { store.selectTarget(id: $0) }
                )
            ) {
                ForEach(currentTargets, id: \.id) { target in
                    Text(targetLabel(target)).tag(target.id)
                }
            } label: {
                Label(
                    String(localized: "diffReview.toolbar.target", defaultValue: "Base"),
                    systemImage: "arrow.triangle.branch"
                )
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 190)
            .disabled(currentTargets.count <= 1 || store.isLoading)

            Spacer(minLength: 4)

            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            }

            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: RightSidebarChromeMetrics.controlHeight, height: RightSidebarChromeMetrics.controlHeight)
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading)
            .safeHelp(String(localized: "diffReview.refresh.tooltip", defaultValue: "Refresh Review"))
            .accessibilityLabel(String(localized: "diffReview.refresh.tooltip", defaultValue: "Refresh Review"))
        }
        .rightSidebarChromeBar()
        .rightSidebarChromeBottomBorder()
        .reportRightSidebarChromeGeometryForBonsplitUITest(
            role: .secondaryBar,
            isVisible: true,
            titlebarHeight: RightSidebarChromeMetrics.secondaryBarHeight
        )
    }

    @ViewBuilder
    private var content: some View {
        switch DiffReviewPanelContentState.resolve(
            directory: directory,
            snapshot: store.snapshot,
            phase: store.phase
        ) {
        case .noWorkspace:
            DiffReviewEmptyStateView(
                systemImage: "folder.badge.questionmark",
                title: String(localized: "diffReview.empty.noWorkspace.title", defaultValue: "Open a local git workspace"),
                subtitle: String(localized: "diffReview.empty.noWorkspace.subtitle", defaultValue: "Review is available for local git repositories.")
            )
        case .files(let snapshot):
            DiffReviewFileListView(
                snapshot: snapshot,
                revertingHunkIDs: store.revertingHunkIDs,
                actions: DiffReviewPanelActions(
                    revertHunk: { store.revertHunk($0) }
                )
            )
        case .loading:
            DiffReviewLoadingView()
        case .error(let message):
            DiffReviewErrorView(message: message, retry: store.refresh)
        }
    }

    private var currentTargets: [DiffReviewTarget] {
        store.snapshot?.targets ?? [.workingTree]
    }

    private func targetLabel(_ target: DiffReviewTarget) -> String {
        switch target {
        case .workingTree:
            return String(localized: "diffReview.target.workingTree", defaultValue: "Working Tree")
        case .branch(let branchName):
            return branchName
        }
    }
}

struct DiffReviewPanelActions {
    let revertHunk: (DiffReviewHunk) -> Void
}

private struct DiffReviewFileListView: View {
    let snapshot: DiffReviewSnapshot
    let revertingHunkIDs: Set<String>
    let actions: DiffReviewPanelActions

    var body: some View {
        if snapshot.files.isEmpty {
            DiffReviewEmptyStateView(
                systemImage: "checkmark.circle",
                title: String(localized: "diffReview.empty.noChanges.title", defaultValue: "No changes"),
                subtitle: String(localized: "diffReview.empty.noChanges.subtitle", defaultValue: "The selected comparison has no file changes.")
            )
        } else {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    DiffReviewSummaryRow(snapshot: snapshot)
                    ForEach(snapshot.files) { file in
                        DiffReviewFileSectionView(
                            file: file,
                            canRevertHunks: snapshot.selectedTarget.allowsHunkRevert,
                            revertingHunkIDs: revertingHunkIDs,
                            actions: actions
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.04))
        }
    }
}

private struct DiffReviewSummaryRow: View {
    let snapshot: DiffReviewSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot.selectedTarget.allowsHunkRevert ? "doc.text.magnifyingglass" : "arrow.triangle.branch")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text(summaryText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer(minLength: 10)
            DiffReviewCountLabel(prefix: "+", count: snapshot.totalAddedLineCount, color: .green)
            DiffReviewCountLabel(prefix: "-", count: snapshot.totalDeletedLineCount, color: .red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .rightSidebarChromeBottomBorder()
    }

    private var summaryText: String {
        let fileCount = snapshot.files.count
        if let currentBranch = snapshot.currentBranch, !currentBranch.isEmpty {
            return String(
                localized: "diffReview.summary.withBranch",
                defaultValue: "\(fileCount) files on \(currentBranch)"
            )
        }
        return String(localized: "diffReview.summary.files", defaultValue: "\(fileCount) files")
    }
}

private struct DiffReviewFileSectionView: View {
    let file: DiffReviewFile
    let canRevertHunks: Bool
    let revertingHunkIDs: Set<String>
    let actions: DiffReviewPanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader
            if file.hunks.isEmpty {
                Text(String(localized: "diffReview.file.noTextHunks", defaultValue: "No text hunks to display."))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(file.hunks) { hunk in
                    DiffReviewHunkSectionView(
                        hunk: hunk,
                        canRevert: canRevertHunks,
                        isReverting: revertingHunkIDs.contains(hunk.id),
                        actions: actions
                    )
                }
            }
        }
        .rightSidebarChromeBottomBorder()
    }

    private var fileHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(statusColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.path)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let oldPath = file.oldPath {
                    Text(verbatim: oldPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(minWidth: 180, alignment: .leading)
            Spacer(minLength: 10)
            Text(statusLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(statusColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(statusColor.opacity(0.14))
                )
            DiffReviewCountLabel(prefix: "+", count: file.addedLineCount, color: .green)
            DiffReviewCountLabel(prefix: "-", count: file.deletedLineCount, color: .red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.50))
    }

    private var statusLabel: String {
        switch file.status {
        case .modified:
            return String(localized: "diffReview.file.modified", defaultValue: "Modified")
        case .added:
            return String(localized: "diffReview.file.added", defaultValue: "Added")
        case .deleted:
            return String(localized: "diffReview.file.deleted", defaultValue: "Deleted")
        case .renamed:
            return String(localized: "diffReview.file.renamed", defaultValue: "Renamed")
        case .copied:
            return String(localized: "diffReview.file.copied", defaultValue: "Copied")
        case .untracked:
            return String(localized: "diffReview.file.untracked", defaultValue: "Untracked")
        case .binary:
            return String(localized: "diffReview.file.binary", defaultValue: "Binary")
        }
    }

    private var statusSymbol: String {
        switch file.status {
        case .modified:
            return "pencil"
        case .added, .untracked:
            return "plus"
        case .deleted:
            return "minus"
        case .renamed:
            return "arrow.right"
        case .copied:
            return "doc.on.doc"
        case .binary:
            return "doc.fill"
        }
    }

    private var statusColor: Color {
        switch file.status {
        case .added, .untracked:
            return .green
        case .deleted:
            return .red
        case .renamed, .copied:
            return .blue
        case .binary:
            return .secondary
        case .modified:
            return .orange
        }
    }
}

private struct DiffReviewHunkSectionView: View {
    let hunk: DiffReviewHunk
    let canRevert: Bool
    let isReverting: Bool
    let actions: DiffReviewPanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hunkHeader
            ForEach(hunk.lines) { line in
                DiffReviewLineView(line: line)
            }
        }
    }

    private var hunkHeader: some View {
        HStack(spacing: 8) {
            Text(verbatim: hunk.sectionHeading ?? hunk.header)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            DiffReviewCountLabel(prefix: "+", count: hunk.addedLineCount, color: .green)
            DiffReviewCountLabel(prefix: "-", count: hunk.deletedLineCount, color: .red)
            if canRevert {
                Button {
                    actions.revertHunk(hunk)
                } label: {
                    if isReverting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .disabled(isReverting)
                .frame(width: 22, height: 22)
                .safeHelp(
                    isReverting
                        ? String(localized: "diffReview.hunk.reverting", defaultValue: "Reverting...")
                        : String(localized: "diffReview.hunk.revert", defaultValue: "Revert Hunk")
                )
                .accessibilityLabel(String(localized: "diffReview.hunk.revert", defaultValue: "Revert Hunk"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
    }
}

private struct DiffReviewLineView: View {
    let line: DiffReviewLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(verbatim: line.marker)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(markerColor)
                .frame(width: 22, alignment: .center)
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 18)
        .background(backgroundColor)
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .addition:
            return Color.green.opacity(0.13)
        case .deletion:
            return Color.red.opacity(0.13)
        case .metadata:
            return Color.orange.opacity(0.10)
        case .context:
            return Color.clear
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition:
            return .green
        case .deletion:
            return .red
        case .metadata:
            return .orange
        case .context:
            return .secondary
        }
    }

    private var textColor: Color {
        line.kind == .metadata ? .secondary : .primary
    }
}

private struct DiffReviewCountLabel: View {
    let prefix: String
    let count: Int
    let color: Color

    var body: some View {
        Text(verbatim: "\(prefix)\(count)")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundColor(count == 0 ? .secondary : color)
            .frame(minWidth: 26, alignment: .trailing)
    }
}

private struct DiffReviewLoadingView: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "diffReview.loading", defaultValue: "Loading diff..."))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiffReviewErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.orange)
            Text(String(localized: "diffReview.error.title", defaultValue: "Review unavailable"))
                .font(.system(size: 13, weight: .semibold))
            Text(verbatim: message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            Button(String(localized: "diffReview.retry", defaultValue: "Retry"), action: retry)
                .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiffReviewEmptyStateView: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
