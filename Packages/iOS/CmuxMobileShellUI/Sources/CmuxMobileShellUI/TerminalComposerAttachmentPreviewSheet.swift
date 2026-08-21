#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Presents one staged terminal-composer attachment through the system Quick
/// Look preview. The staged bytes live in memory (they are sent, not kept, as
/// files), so the sheet materializes them into an app-owned temporary file
/// named after the attachment for its lifetime and deletes that file when the
/// sheet closes.
struct TerminalComposerAttachmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let attachment: MobilePendingAttachment

    /// The materialized preview file, set once the off-main write completes.
    /// Held with its parent directory so dismissal removes both.
    @State private var previewFileURL: URL?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let previewFileURL {
                    MobileAttachmentQuickLookView(
                        fileURL: previewFileURL,
                        title: attachment.displayName,
                        accessibilityIdentifier: "MobileComposerAttachmentQuickLook"
                    )
                } else if failed {
                    ContentUnavailableView(
                        L10n.string(
                            "mobile.composer.attachment.previewFailed",
                            defaultValue: "Couldn’t Preview Attachment"
                        ),
                        systemImage: "eye.slash"
                    )
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(attachment.displayName)
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
        .accessibilityIdentifier("MobileComposerAttachmentPreview")
        .task {
            await materializePreviewFile()
        }
        .onDisappear {
            removePreviewFile()
        }
    }

    /// Write the staged bytes into `tmp/<unique dir>/<display name>` off the
    /// main actor. The directory name carries the uniqueness so the visible
    /// file can keep the user's original name (Quick Look shows the title and
    /// types by extension).
    private func materializePreviewFile() async {
        guard previewFileURL == nil else { return }
        let data = attachment.data
        let fileName = Self.previewFileName(
            displayName: attachment.displayName,
            format: attachment.format
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-composer-preview-\(UUID().uuidString)",
                isDirectory: true
            )
        let destination = directory.appendingPathComponent(fileName)
        let written: Bool = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try data.write(to: destination, options: .atomic)
                return true
            } catch {
                try? FileManager.default.removeItem(at: directory)
                return false
            }
        }.value
        if written {
            previewFileURL = destination
        } else {
            failed = true
        }
    }

    private func removePreviewFile() {
        guard let previewFileURL else { return }
        let directory = previewFileURL.deletingLastPathComponent()
        self.previewFileURL = nil
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A safe on-disk name for the preview file: the display name stripped of
    /// path separators, falling back to a format-typed generic name so Quick
    /// Look can always infer the content type.
    static func previewFileName(displayName: String, format: String) -> String {
        let sanitized = displayName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !sanitized.isEmpty, sanitized != "." , sanitized != ".." {
            return sanitized
        }
        return format.isEmpty ? "attachment" : "attachment.\(format)"
    }
}
#endif
