import CmuxDiffModel
import CmuxMobileRPC
import CmuxMobileSupport
import SwiftUI

struct DiffReviewFileView: View {
    @Bindable var session: DiffReviewSession
    let fetchFile: (String) async throws -> MobileWorkspaceDiffFileResponse

    @State private var loadedPath: String?
    @State private var hunks: [DiffHunk] = []
    @State private var isLoading = false
    @State private var isTruncated = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            bottomBar
        }
        .navigationTitle(session.currentFile.map { fileTitle($0.path) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: session.markBookmark) {
                    Image(systemName: session.bookmark == nil ? "bookmark" : "bookmark.fill")
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(L10n.string("mobile.diff.bookmark", defaultValue: "Bookmark"))
            }
        }
        .overlay(alignment: .top) {
            if session.hasJumpBackTarget {
                Button(action: session.jumpToBookmark) {
                    Label(
                        L10n.string("mobile.diff.jumpBack", defaultValue: "Jump Back"),
                        systemImage: "arrow.uturn.backward"
                    )
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .accessibilityIdentifier("DiffReviewJumpBack")
            }
        }
        .task(id: session.currentFile?.path) {
            await loadCurrentFile()
        }
        .sensoryFeedback(.selection, trigger: session.navigationGeneration)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView(
                L10n.string("mobile.diff.loadFailed", defaultValue: "Could not load diff"),
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if let hunk = currentHunk {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isTruncated {
                        Label(
                            L10n.string("mobile.diff.truncated", defaultValue: "Diff truncated"),
                            systemImage: "scissors"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    }
                    DiffReviewHunkView(hunk: hunk)
                }
                .padding(.vertical, 12)
            }
            .gesture(swipeGesture)
        } else {
            ContentUnavailableView(
                L10n.string("mobile.diff.noHunks", defaultValue: "No diff hunks"),
                systemImage: "doc.text"
            )
            .gesture(swipeGesture)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button(action: session.moveBackward) {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .disabled(!session.canMoveBackward)
            .accessibilityLabel(L10n.string("mobile.diff.previousHunk", defaultValue: "Previous Hunk"))

            Text(hunkCounterText)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)

            Button(action: session.moveForward) {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .disabled(!session.canMoveForward)
            .accessibilityLabel(L10n.string("mobile.diff.nextHunk", defaultValue: "Next Hunk"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var currentHunk: DiffHunk? {
        guard hunks.indices.contains(session.currentHunkIndex) else { return nil }
        return hunks[session.currentHunkIndex]
    }

    private var hunkCounterText: String {
        let count = max(hunks.count, 0)
        guard count > 0 else {
            return L10n.string("mobile.diff.hunkCounterEmpty", defaultValue: "Hunk 0/0")
        }
        return String(
            format: L10n.string("mobile.diff.hunkCounterFormat", defaultValue: "Hunk %d/%d"),
            min(session.currentHunkIndex + 1, count),
            count
        )
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                if value.translation.width < -60 {
                    session.moveForward()
                } else if value.translation.width > 60 {
                    session.moveBackward()
                }
            }
    }

    private func loadCurrentFile() async {
        guard let file = session.currentFile else { return }
        isLoading = true
        errorMessage = nil
        loadedPath = file.path
        defer { isLoading = false }
        do {
            let response = try await fetchFile(file.path)
            guard loadedPath == file.path else { return }
            let result = UnifiedDiffParser().parse(response.unifiedDiff, isTruncated: response.truncated)
            hunks = result.hunks
            isTruncated = result.isTruncated
            session.recordHunkCount(result.hunks.count, for: file.path)
        } catch {
            guard loadedPath == file.path else { return }
            hunks = []
            isTruncated = false
            session.recordHunkCount(0, for: file.path)
            errorMessage = error.localizedDescription
        }
    }

    private func fileTitle(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

private struct DiffReviewHunkView: View {
    let hunk: DiffHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: hunk.header)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hunk.lines) { line in
                        DiffReviewLineView(line: line)
                    }
                }
            }
        }
    }
}

private struct DiffReviewLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 8) {
            Text(lineNumber)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            Text(verbatim: marker + line.text)
                .foregroundStyle(foreground)
        }
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var lineNumber: String {
        if let newLine = line.newLine {
            return String(newLine)
        }
        if let oldLine = line.oldLine {
            return String(oldLine)
        }
        return ""
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }

    private var foreground: Color {
        switch line.kind {
        case .addition: return .green
        case .deletion: return .red
        case .context: return .primary.opacity(0.78)
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: return .green.opacity(0.08)
        case .deletion: return .red.opacity(0.08)
        case .context: return .clear
        }
    }
}
