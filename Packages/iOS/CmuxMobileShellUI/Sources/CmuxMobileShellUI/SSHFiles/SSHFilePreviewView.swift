#if os(iOS)
import CmuxMobileSupport
import QuickLook
import SwiftUI

/// Downloads one remote file, then previews it: Quick Look for anything it
/// understands (images, PDFs, text, media), a plain-text reader for other
/// UTF-8 files. Share and Save to Files work on the downloaded copy.
struct SSHFilePreviewView: View {
    let model: SSHFileBrowserModel
    let remotePath: String
    let name: String
    let actions: SSHFileBrowserActions

    private enum Phase: Equatable {
        case downloading
        case quickLook(URL)
        case text(URL, String)
        case unsupported(URL)
        case failed(String)
    }

    @State private var phase: Phase = .downloading
    @State private var isSavingToFiles = false
    /// Largest file shown in the plain-text reader.
    private static let textPreviewLimit = 2 * 1_024 * 1_024

    var body: some View {
        content
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task(id: remotePath) { await load() }
            .fileMover(isPresented: $isSavingToFiles, file: localURL) { result in
                if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                    model.actionError = L10n.string(
                        "mobile.ssh.files.error.saveFailed",
                        defaultValue: "Couldn't save the file to Files."
                    )
                }
                // The move consumed the scratch copy; fetch it again so
                // Share and preview keep working.
                if case .success = result {
                    Task { await load() }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .downloading:
            VStack(spacing: 12) {
                if let fraction = model.transfer?.fraction {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 240)
                } else {
                    ProgressView()
                }
                Text(L10n.string("mobile.ssh.files.preview.downloading", defaultValue: "Downloading…"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .quickLook(let url):
            MobileAttachmentQuickLookView(
                fileURL: url,
                title: name,
                accessibilityIdentifier: "ssh.files.preview"
            )
            .ignoresSafeArea(edges: .bottom)
        case .text(_, let text):
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("ssh.files.preview.text")
        case .unsupported:
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.ssh.files.preview.unsupported", defaultValue: "No Preview Available"),
                    systemImage: "doc"
                )
            } description: {
                Text(L10n.string(
                    "mobile.ssh.files.preview.unsupportedMessage",
                    defaultValue: "Use Share or Save to Files to open it in another app."
                ))
            }
        case .failed(let message):
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.ssh.files.preview.failed", defaultValue: "Can't Download File"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(message)
            } actions: {
                Button(L10n.string("mobile.ssh.files.retry", defaultValue: "Try Again")) {
                    Task { await load() }
                }
            }
        }
    }

    private var localURL: URL? {
        switch phase {
        case .quickLook(let url), .text(let url, _), .unsupported(let url): url
        case .downloading, .failed: nil
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(L10n.string("mobile.ssh.files.done", defaultValue: "Done"), action: actions.done)
        }
        if let url = localURL {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ShareLink(item: url) {
                        Label(
                            L10n.string("mobile.ssh.files.share", defaultValue: "Share…"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    Button {
                        isSavingToFiles = true
                    } label: {
                        Label(
                            L10n.string("mobile.ssh.files.saveToFiles", defaultValue: "Save to Files…"),
                            systemImage: "folder"
                        )
                    }
                    .accessibilityIdentifier("ssh.files.saveToFiles")
                    if let insertPath = actions.insertPath {
                        Button {
                            insertPath(remotePath)
                        } label: {
                            Label(
                                L10n.string("mobile.ssh.files.insertPath", defaultValue: "Insert Path in Terminal"),
                                systemImage: "text.cursor"
                            )
                        }
                    }
                } label: {
                    Label(
                        L10n.string("mobile.ssh.files.share", defaultValue: "Share…"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .accessibilityIdentifier("ssh.files.share")
            }
        }
    }

    private func load() async {
        phase = .downloading
        do {
            let url = try await model.download(remotePath, name: name)
            phase = Self.phase(for: url)
        } catch {
            phase = .failed(SSHFileBrowserModel.describe(error))
        }
    }

    private static func phase(for url: URL) -> Phase {
        if QLPreviewController.canPreview(url as NSURL) {
            return .quickLook(url)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        if size <= textPreviewLimit,
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            return .text(url, text)
        }
        return .unsupported(url)
    }
}
#endif
