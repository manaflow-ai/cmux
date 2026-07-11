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
        .refreshable { await reload() }
        .task { await reloadIfNeeded() }
        .overlay {
            if isLoading, session.files.isEmpty {
                ProgressView()
            }
        }
        .navigationDestination(isPresented: $isFilePresented) {
            DiffReviewFileView(
                session: session,
                fetchFile: { path, oldPath in try await fetchFile(path, oldPath, repoRoot) }
            )
        }
    }

    private func reloadIfNeeded() async {
        guard session.files.isEmpty else { return }
        await reload()
    }

    private func reload() async {
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
            guard statusLoadGeneration == generation, !Task.isCancelled else { return }
            session.setFiles(response.files)
            repoRoot = response.repoRoot
            isListTruncated = response.truncated
        } catch is CancellationError {
            return
        } catch {
            guard statusLoadGeneration == generation, !Task.isCancelled else { return }
            errorMessage = DiffReviewErrorPresentation.message(for: error)
        }
    }
}
