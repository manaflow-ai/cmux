import CmuxDiffModel
import CmuxMobileRPC
import CmuxMobileSupport
import SwiftUI

struct DiffReviewFileView: View {
    @Bindable var session: DiffReviewSession
    let fetchFile: (String, String?) async throws -> MobileWorkspaceDiffFileResponse
    private let parser = DiffReviewParser()

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var loadState = DiffReviewFileLoadState.idle
    @State private var activeRequest: DiffReviewFileLoadRequest?
    @State private var loadAttempt = 0
    @State private var isFileSwitcherPresented = false
    @State private var fileSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            content
            if session.currentFile != nil {
                Divider()
                bottomBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.currentFile != nil {
                ToolbarItem(placement: .principal) {
                    fileSwitcher
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: session.markBookmark) {
                        Image(systemName: isCurrentHunkBookmarked ? "bookmark.fill" : "bookmark")
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(
                        L10n.string("mobile.diff.bookmark", defaultValue: "Bookmark this hunk")
                    )
                    .accessibilityValue(
                        isCurrentHunkBookmarked
                            ? L10n.string("mobile.diff.bookmarked", defaultValue: "Bookmarked")
                            : L10n.string("mobile.diff.notBookmarked", defaultValue: "Not bookmarked")
                    )
                }
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
                    .frame(minHeight: 44)
                    .background(.regularMaterial, in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityIdentifier("DiffReviewJumpBack")
            }
        }
        .task(id: currentRequest) {
            await loadCurrentFile(request: currentRequest)
        }
        .sheet(isPresented: $isFileSwitcherPresented) {
            filePicker
        }
        .sensoryFeedback(.selection, trigger: session.navigationGeneration)
    }

    @ViewBuilder
    private var content: some View {
        switch visibleLoadState {
        case .empty:
            ContentUnavailableView(
                L10n.string("mobile.diff.empty", defaultValue: "No changes"),
                systemImage: "checkmark.circle"
            )
        case .idle, .loading:
            ProgressView(
                L10n.string("mobile.diff.loading", defaultValue: "Loading diff")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(_, let message):
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.diff.loadFailed", defaultValue: "Could not load diff"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(message)
            } actions: {
                Button(L10n.string("mobile.diff.retry", defaultValue: "Retry")) {
                    loadAttempt &+= 1
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("DiffReviewRetry")
            }
        case .loaded(_, let hunks, let isTruncated):
            if let hunk = currentHunk(in: hunks) {
                VStack(spacing: 0) {
                    if isTruncated {
                        Label(
                            L10n.string("mobile.diff.truncated", defaultValue: "Diff truncated"),
                            systemImage: "scissors"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    }
                    DiffReviewHunkView(
                        hunk: hunk,
                        position: session.currentHunkIndex + 1,
                        total: hunks.count,
                        moveBackward: session.moveBackward,
                        moveForward: session.moveForward
                    )
                }
            } else {
                if let file = session.currentFile,
                   let rename = DiffReviewRenamePresentation(file: file) {
                    ContentUnavailableView {
                        Label(
                            L10n.string("mobile.diff.status.renamed", defaultValue: "Renamed"),
                            systemImage: "arrow.right"
                        )
                    } description: {
                        Text(rename.text)
                    }
                    .contentShape(.rect)
                    .gesture(hunkSwipeGesture)
                } else {
                    ContentUnavailableView(
                        L10n.string("mobile.diff.noHunks", defaultValue: "No diff hunks"),
                        systemImage: "doc.text"
                    )
                    .contentShape(.rect)
                    .gesture(hunkSwipeGesture)
                }
            }
        }
    }

    private var fileSwitcher: some View {
        Button {
            isFileSwitcherPresented = true
        } label: {
            VStack(spacing: 0) {
                Text(currentFileName)
                    .font(.headline)
                    .lineLimit(1)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(session.currentFile?.path ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 220)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: L10n.string(
                    "mobile.diff.switchFileAccessibilityFormat",
                    defaultValue: "Current file, %@. Choose another file"
                ),
                session.currentFile?.path ?? ""
            )
        )
        .accessibilityIdentifier("DiffReviewFileSwitcher")
    }

    private var filePicker: some View {
        NavigationStack {
            List(filteredFiles) { file in
                Button {
                    session.openFile(path: file.path)
                    fileSearchText = ""
                    isFileSwitcherPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Text(file.path)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if file.path == session.currentFile?.path {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(.rect)
                }
                .accessibilityIdentifier("DiffReviewFilePickerRow")
            }
            .searchable(text: $fileSearchText)
            .navigationTitle(L10n.string("mobile.diff.chooseFile", defaultValue: "Choose File"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        fileSearchText = ""
                        isFileSwitcherPresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var filteredFiles: [MobileWorkspaceDiffStatusResponse.File] {
        let query = fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return session.files }
        return session.files.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button(action: session.moveBackward) {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .disabled(!session.canMoveBackward)
            .accessibilityLabel(L10n.string("mobile.diff.previousHunk", defaultValue: "Previous Hunk"))

            Text(hunkCounterText)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("DiffReviewHunkCounter")

            Button(action: session.moveForward) {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .disabled(!session.canMoveForward)
            .accessibilityLabel(L10n.string("mobile.diff.nextHunk", defaultValue: "Next Hunk"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxHeight: 60)
        .background(.bar)
    }

    private var currentRequest: DiffReviewFileLoadRequest {
        DiffReviewFileLoadRequest(
            path: session.currentFile?.path,
            oldPath: session.currentFile?.oldPath,
            attempt: loadAttempt
        )
    }

    private var visibleLoadState: DiffReviewFileLoadState {
        loadState.visible(for: session.currentFile?.path)
    }

    private var currentFileName: String {
        guard let path = session.currentFile?.path else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var isCurrentHunkBookmarked: Bool {
        guard let currentFile = session.currentFile, let bookmark = session.bookmark else {
            return false
        }
        return bookmark.filePath == currentFile.path && bookmark.hunkIndex == session.currentHunkIndex
    }

    private var hunkCounterText: String {
        switch visibleLoadState {
        case .empty:
            return L10n.string("mobile.diff.empty", defaultValue: "No changes")
        case .idle, .loading:
            return L10n.string("mobile.diff.loading", defaultValue: "Loading diff")
        case .failed:
            return L10n.string("mobile.diff.unavailable", defaultValue: "Diff unavailable")
        case .loaded(_, let hunks, _):
            guard !hunks.isEmpty else {
                return L10n.string("mobile.diff.hunkCounterEmpty", defaultValue: "Hunk 0/0")
            }
            return String(
                format: L10n.string("mobile.diff.hunkCounterFormat", defaultValue: "Hunk %d/%d"),
                min(session.currentHunkIndex + 1, hunks.count),
                hunks.count
            )
        }
    }

    private var hunkSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 36)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) >= 80, abs(horizontal) > abs(vertical) * 1.5 else { return }
                if horizontal < 0 {
                    session.moveForward()
                } else {
                    session.moveBackward()
                }
            }
    }

    private func currentHunk(in hunks: [DiffHunk]) -> DiffHunk? {
        guard hunks.indices.contains(session.currentHunkIndex) else { return nil }
        return hunks[session.currentHunkIndex]
    }

    private func loadCurrentFile(request: DiffReviewFileLoadRequest) async {
        guard let path = request.path else {
            activeRequest = nil
            loadState = .idle
            return
        }
        activeRequest = request
        loadState = .loading(path: path)
        do {
            let response = try await fetchFile(path, request.oldPath)
            guard activeRequest == request, !Task.isCancelled else { return }
            guard response.path == path else {
                throw MobileShellConnectionError.invalidResponse
            }
            let result = await parser.parse(response)
            guard activeRequest == request, !Task.isCancelled else { return }
            loadState = .loaded(path: path, hunks: result.hunks, isTruncated: result.isTruncated)
            session.recordHunkCount(result.hunks.count, for: path)
        } catch is CancellationError {
            return
        } catch {
            guard activeRequest == request, !Task.isCancelled else { return }
            loadState = .failed(
                path: path,
                message: DiffReviewErrorPresentation(error: error).message
            )
            // A transient failure has no authoritative hunk count. Preserve
            // the bookmark, current hunk, and pending cross-file navigation
            // until a successful retry reports the file's parsed hunks.
        }
    }

}
