import CmuxMobileRPC
import CmuxMobileSupport
import SwiftUI

struct DiffReviewFilesView: View {
    let workspaceName: String
    let fetchStatus: () async throws -> MobileWorkspaceDiffStatusResponse
    let fetchFile: (String) async throws -> MobileWorkspaceDiffFileResponse

    @State private var session = DiffReviewSession()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isFilePresented = false

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
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
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
            DiffReviewFileView(session: session, fetchFile: fetchFile)
        }
    }

    private func reloadIfNeeded() async {
        guard session.files.isEmpty else { return }
        await reload()
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await fetchStatus()
            session.setFiles(response.files)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DiffReviewFileRow: View {
    let file: MobileWorkspaceDiffStatusResponse.File
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                statusBadge
                VStack(alignment: .leading, spacing: 3) {
                    Text(fileName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !directory.isEmpty {
                        Text(directory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                counts
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("DiffReviewFileRow-\(file.path)")
    }

    private var statusBadge: some View {
        Text(file.status)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(statusColor, in: .rect(cornerRadius: 6))
            .accessibilityHidden(true)
    }

    private var counts: some View {
        HStack(spacing: 6) {
            if let additions = file.additions {
                Text(verbatim: "+\(additions)")
                    .foregroundStyle(.green)
            }
            if let deletions = file.deletions {
                Text(verbatim: "-\(deletions)")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var fileName: String {
        URL(fileURLWithPath: file.path).lastPathComponent
    }

    private var directory: String {
        let directory = (file.path as NSString).deletingLastPathComponent
        return directory == "." ? "" : directory
    }

    private var statusColor: Color {
        switch file.status {
        case "A", "U":
            return .green
        case "D":
            return .red
        case "R":
            return .blue
        default:
            return .orange
        }
    }
}
