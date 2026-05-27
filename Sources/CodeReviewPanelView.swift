import AppKit
import Foundation
import SwiftUI

struct CodeReviewPanelView: View {
    let store: GitDiffReviewStore
    let rootPath: String?

    private var normalizedRootPath: String? {
        let trimmed = rootPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            store.setRootPath(normalizedRootPath)
        }
        .onChange(of: normalizedRootPath) { _, newValue in
            store.setRootPath(newValue)
        }
        .accessibilityIdentifier("CodeReviewPanel")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "codeReview.title", defaultValue: "Code Review"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(normalizedRootPath == nil || isLoading)
            .safeHelp(String(localized: "codeReview.refresh", defaultValue: "Refresh"))
            .accessibilityLabel(String(localized: "codeReview.refresh", defaultValue: "Refresh"))
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private var headerSubtitle: String {
        switch store.phase {
        case .loaded(let snapshot):
            return String.localizedStringWithFormat(
                String(localized: "codeReview.header.loaded", defaultValue: "%@ - %@"),
                snapshot.branch,
                snapshot.repositoryRoot
            )
        case .loading(let rootPath), .failed(let rootPath, _):
            return rootPath
        case .idle:
            return normalizedRootPath ?? String(localized: "codeReview.noWorkspace.title", defaultValue: "No workspace directory")
        }
    }

    private var isLoading: Bool {
        if case .loading = store.phase {
            return true
        }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            CodeReviewEmptyStateView(
                systemImage: "folder.badge.questionmark",
                title: String(localized: "codeReview.noWorkspace.title", defaultValue: "No workspace directory"),
                message: String(localized: "codeReview.noWorkspace.message", defaultValue: "Open a local workspace directory to review changes.")
            )
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "codeReview.loading", defaultValue: "Loading diff..."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(_, let error):
            CodeReviewEmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: String(localized: "codeReview.error.title", defaultValue: "Unable to load diff"),
                message: error.displayMessage
            )
        case .loaded(let snapshot):
            if snapshot.files.isEmpty {
                CodeReviewEmptyStateView(
                    systemImage: "checkmark.circle",
                    title: String(localized: "codeReview.noChanges.title", defaultValue: "No changes"),
                    message: String(localized: "codeReview.noChanges.message", defaultValue: "This working tree matches HEAD.")
                )
            } else {
                CodeReviewSnapshotView(snapshot: snapshot)
            }
        }
    }
}

private struct CodeReviewSnapshotView: View {
    let snapshot: GitDiffReviewSnapshot

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                CodeReviewSummaryView(snapshot: snapshot)
                ForEach(snapshot.files) { file in
                    CodeReviewFileSection(file: file)
                }
            }
            .padding(10)
        }
    }
}

private struct CodeReviewSummaryView: View {
    let snapshot: GitDiffReviewSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Text(fileCountText)
            .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 0)

            Text(
                String.localizedStringWithFormat(
                    String(localized: "codeReview.summary.churn", defaultValue: "+%lld -%lld"),
                    snapshot.additions,
                    snapshot.deletions
                )
            )
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var fileCountText: String {
        if snapshot.files.count == 1 {
            return String.localizedStringWithFormat(
                String(localized: "codeReview.summary.file", defaultValue: "%lld file"),
                snapshot.files.count
            )
        }

        return String.localizedStringWithFormat(
            String(localized: "codeReview.summary.files", defaultValue: "%lld files"),
            snapshot.files.count
        )
    }
}

private struct CodeReviewFileSection: View {
    let file: GitDiffReviewFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if file.hunks.isEmpty {
                Text(emptyDiffMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(file.hunks.indices, id: \.self) { hunkIndex in
                    CodeReviewHunkView(hunk: file.hunks[hunkIndex])
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: file.path)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Text(file.status.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(
                String.localizedStringWithFormat(
                    String(localized: "codeReview.file.churn", defaultValue: "+%lld -%lld"),
                    file.additions,
                    file.deletions
                )
            )
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
    }

    private var emptyDiffMessage: String {
        if file.status == .untracked {
            return String(localized: "codeReview.untracked.message", defaultValue: "Untracked file; diff content is not available yet.")
        }
        return String(localized: "codeReview.noTextDiff.message", defaultValue: "No textual diff is available for this file.")
    }
}

private struct CodeReviewHunkView: View {
    let hunk: GitDiffReviewHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: hunk.header)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))

            ForEach(hunk.lines.indices, id: \.self) { lineIndex in
                CodeReviewDiffLineView(line: hunk.lines[lineIndex])
            }
        }
    }
}

private struct CodeReviewDiffLineView: View {
    let line: GitDiffReviewLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            lineNumberText(line.oldLineNumber)
            lineNumberText(line.newLineNumber)
            Text(verbatim: linePrefix)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(prefixColor)
                .frame(width: 16, alignment: .center)
            Text(verbatim: line.content.isEmpty ? " " : line.content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .lineLimit(nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 8)
        .background(backgroundColor)
    }

    private func lineNumberText(_ number: Int?) -> some View {
        Text(verbatim: number.map { String($0) } ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 38, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var linePrefix: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .note: return "\\"
        case .context: return " "
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .addition: return Color(nsColor: .systemGreen)
        case .deletion: return Color(nsColor: .systemRed)
        case .note: return Color(nsColor: .secondaryLabelColor)
        case .context: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var foregroundColor: Color {
        switch line.kind {
        case .addition: return Color(nsColor: .systemGreen)
        case .deletion: return Color(nsColor: .systemRed)
        case .note: return Color(nsColor: .secondaryLabelColor)
        case .context: return .primary
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .addition:
            return Color(nsColor: .systemGreen).opacity(0.10)
        case .deletion:
            return Color(nsColor: .systemRed).opacity(0.10)
        case .note:
            return Color(nsColor: .controlBackgroundColor).opacity(0.50)
        case .context:
            return Color.clear
        }
    }
}

private struct CodeReviewEmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
