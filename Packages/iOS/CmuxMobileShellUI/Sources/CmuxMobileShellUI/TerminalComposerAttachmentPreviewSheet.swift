#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Quick Look preview for one staged terminal-composer attachment.
///
/// Pending attachments hold their bytes in memory (unlike the task composer's
/// file-backed staging), so the sheet materializes them into an app-owned
/// temp file — named with the user-visible file name so Quick Look renders
/// the right document type and title — and removes the wrapper directory when
/// the sheet goes away.
struct TerminalComposerAttachmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let attachment: MobilePendingAttachment

    private enum MaterializationState {
        case loading
        case ready(URL)
        case failed
    }

    @State private var state: MaterializationState = .loading

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(previewTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string(
                            "mobile.common.done",
                            defaultValue: "Done"
                        )) {
                            dismiss()
                        }
                    }
                }
        }
        .task(id: attachment.id) {
            await materialize()
        }
        .onDisappear {
            cleanUpMaterializedFile()
        }
        .accessibilityIdentifier("MobileComposerAttachmentPreview")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let fileURL):
            MobileAttachmentQuickLookView(
                fileURL: fileURL,
                title: previewTitle,
                accessibilityIdentifier: "MobileComposerAttachmentQuickLook"
            )
        case .failed:
            Label(
                L10n.string(
                    "mobile.composer.attachment.previewFailed",
                    defaultValue: "This attachment couldn’t be previewed."
                ),
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The user-visible name: the file's own name for file chips, a generated
    /// `image.<ext>` for images (their chips render thumbnails, not names).
    private var previewTitle: String {
        attachment.displayName ?? "image.\(attachment.format)"
    }

    private static let wrapperPrefix = "cmux-composer-preview-"

    /// Write the staged bytes off the main actor into a wrapper directory that
    /// carries the uniqueness, so the file inside keeps the user-visible name
    /// (Quick Look shows it and picks the renderer from its extension).
    private func materialize() async {
        guard case .loading = state else { return }
        let data = attachment.data
        // A path separator or colon in a display name would escape the wrapper
        // or read as a volume separator.
        let fileName = previewTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let wrapper = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                Self.wrapperPrefix + UUID().uuidString,
                isDirectory: true
            )
        let destination = wrapper.appendingPathComponent(
            fileName.isEmpty ? UUID().uuidString : fileName
        )
        let written: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask(priority: .utility) {
                do {
                    try FileManager.default.createDirectory(
                        at: wrapper,
                        withIntermediateDirectories: true
                    )
                    try data.write(to: destination, options: .atomic)
                    return true
                } catch {
                    try? FileManager.default.removeItem(at: wrapper)
                    return false
                }
            }
            return await group.next() ?? false
        }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: wrapper)
            return
        }
        state = written ? .ready(destination) : .failed
    }

    private func cleanUpMaterializedFile() {
        guard case .ready(let fileURL) = state else { return }
        let wrapper = fileURL.deletingLastPathComponent()
        guard wrapper.lastPathComponent.hasPrefix(Self.wrapperPrefix) else {
            return
        }
        try? FileManager.default.removeItem(at: wrapper)
    }
}
#endif
