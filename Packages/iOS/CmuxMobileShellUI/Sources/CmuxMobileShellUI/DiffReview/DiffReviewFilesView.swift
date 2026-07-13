import CmuxMobileRPC
import CmuxMobileSupport
import SwiftUI

struct DiffReviewFilesView: View {
    let workspaceName: String
    let fetchStatus: () async throws -> MobileWorkspaceDiffStatusResponse
    let fetchFile: (String, String?, String) async throws -> MobileWorkspaceDiffFileResponse

    @State private var session = DiffReviewSession()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isFilePresented = false
    @State private var isListTruncated = false
    @State private var statusLoadGeneration = 0
    @State private var repoRoot = ""

    var body: some View {
        List {
            if session.files.isEmpty, !isLoading, errorMessage == nil {
                ContentUnavailableView(
                    L10n.string("mobile.diff.empty", defaultValue: "No changes"),
                    systemImage: "checkmark.circle"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(Array(session.files.enumerated()), id: \.element.id) { index, file in
                    DiffReviewFileRow(file: file) {
                        session.openFile(at: index)
                        isFilePresented = true
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 8))
                }
            }
            if isListTruncated {
                Label(
                    L10n.string("mobile.diff.fileListTruncated", defaultValue: "File list truncated"),
                    systemImage: "scissors"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(L10n.string("mobile.diff.reviewChanges", defaultValue: "Review Changes"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { _ = await reload() }
        .task { await reloadIfNeeded() }
        .overlay {
            if isLoading, session.files.isEmpty {
                ProgressView()
            }
        }
        .navigationDestination(isPresented: $isFilePresented) {
            DiffReviewFileView(
                session: session,
                fetchFile: { path, oldPath in
                    try await fetchFileWithRepositoryRecovery(path: path, oldPath: oldPath)
                }
            )
        }
    }

    private func reloadIfNeeded() async {
        guard session.files.isEmpty else { return }
        _ = await reload()
    }

    private func reload() async -> Bool {
        statusLoadGeneration &+= 1
        let generation = statusLoadGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if statusLoadGeneration == generation {
                isLoading = false
            }
        }
        do {
            let response = try await fetchStatus()
            guard statusLoadGeneration == generation, !Task.isCancelled else { return false }
            session.setFiles(response.files)
            repoRoot = response.repoRoot
            isListTruncated = response.truncated
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard statusLoadGeneration == generation, !Task.isCancelled else { return false }
            errorMessage = DiffReviewErrorPresentation(error: error).message
            return false
        }
    }

    private func fetchFileWithRepositoryRecovery(
        path: String,
        oldPath: String?
    ) async throws -> MobileWorkspaceDiffFileResponse {
        let retry = DiffReviewRepositoryRetry(reloadStatus: reload)
        return try await retry.run { attempt in
            switch attempt {
            case .initial:
                return try await fetchFile(path, oldPath, repoRoot)
            case .reloaded:
                guard let refreshedFile = session.currentFile,
                      refreshedFile.path == path,
                      refreshedFile.oldPath == oldPath else {
                    // `setFiles` changed the load request. Let the view's
                    // request-keyed task restart with that refreshed metadata.
                    throw CancellationError()
                }
                return try await fetchFile(
                    refreshedFile.path,
                    refreshedFile.oldPath,
                    repoRoot
                )
            }
        }
    }
}
