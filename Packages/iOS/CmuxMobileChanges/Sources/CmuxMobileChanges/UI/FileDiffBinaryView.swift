internal import Foundation
internal import SwiftUI

struct FileDiffBinaryView: View {
    let fileIndex: Int
    let file: ChangedFileItem
    @Binding var previewRevision: FileDiffPreviewRevision
    let inlinePreview: (@MainActor @Sendable (Int, FileDiffPreviewRevision) -> AnyView)?

    var body: some View {
        let policy = FileDiffPreviewPolicy(kind: file.kind)
        VStack(spacing: 0) {
            if policy.allowsRevisionSelection {
                Picker(
                    String(localized: "changes.binary.revision", defaultValue: "Revision", bundle: .module),
                    selection: $previewRevision
                ) {
                    Text(String(localized: "changes.binary.before", defaultValue: "Before", bundle: .module))
                        .tag(FileDiffPreviewRevision.base)
                    Text(String(localized: "changes.binary.after", defaultValue: "After", bundle: .module))
                        .tag(FileDiffPreviewRevision.current)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            if let inlinePreview {
                inlinePreview(fileIndex, previewRevision)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fallback
            }
        }
    }

    private var fallback: some View {
        VStack(spacing: 18) {
            fileCard
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.secondary.opacity(0.08))
                .overlay {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 30, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 360, minHeight: 180)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var fileCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(file.displayFilename)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
            if let byteSize = file.byteSize {
                Text(ByteCountFormatter.string(fromByteCount: max(0, byteSize), countStyle: .file))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
