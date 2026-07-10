#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import Foundation
import SwiftUI
import UIKit

/// One immutable artifact snapshot rendered in the terminal gallery.
struct TerminalArtifactGalleryItemView: View {
    enum Layout {
        case list
        case grid
    }

    let artifact: TerminalArtifactReference
    let layout: Layout
    let loader: ChatArtifactLoader
    let open: () -> Void

    @State private var thumbnail: ChatArtifactThumbnail?
    @ScaledMetric(relativeTo: .subheadline) private var gridNameMinHeight: CGFloat = 38
    @ScaledMetric(relativeTo: .caption2) private var gridMetadataMinHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var gridSymbolSize: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var listSymbolSize: CGFloat = 22

    var body: some View {
        Button(action: open) {
            switch layout {
            case .list:
                listContent
            case .grid:
                gridContent
            }
        }
        .buttonStyle(TerminalArtifactGalleryButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(artifact.displayName)
        .accessibilityValue(accessibilityDetail)
        .task(id: "\(artifact.path)#\(Self.thumbnailDimension)") {
            guard artifact.kind == .image else { return }
            thumbnail = try? await loader.thumbnail(
                path: artifact.path,
                maxDimension: Self.thumbnailDimension
            )
        }
    }

    private var listContent: some View {
        HStack(spacing: 12) {
            preview
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(artifact.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let metadataText {
                    Text(metadataText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var gridContent: some View {
        let metadata = metadataText
        return VStack(alignment: .center, spacing: 7) {
            preview
                .aspectRatio(1, contentMode: .fit)

            Text(artifact.displayName)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: gridNameMinHeight, alignment: .top)

            Text(metadata ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .opacity(metadata == nil ? 0 : 1)
                .frame(maxWidth: .infinity, minHeight: gridMetadataMinHeight, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var preview: some View {
        switch layout {
        case .grid:
            framedPreview
        case .list:
            if artifact.kind == .image {
                framedPreview
            } else {
                placeholderSymbol
            }
        }
    }

    private var framedPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))

            previewContent
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var previewContent: some View {
        if let thumbnail,
           let image = UIImage(data: thumbnail.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            placeholderSymbol
        }
    }

    private var placeholderSymbol: some View {
        Image(systemName: symbolName)
            .font(.system(size: layout == .grid ? gridSymbolSize : listSymbolSize, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(symbolTint)
    }

    private var metadataText: String? {
        var components: [String] = []
        if let modifiedAt = artifact.modifiedAt {
            components.append(modifiedAt.formatted(date: .abbreviated, time: .omitted))
        }
        if let size = artifact.size {
            components.append(ByteCountFormatter.string(
                fromByteCount: max(0, size),
                countStyle: .file
            ))
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private var accessibilityDetail: String {
        [localizedKind, metadataText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var localizedKind: String {
        switch artifact.kind {
        case .image:
            String(localized: "terminal.artifact.gallery.kind.image", defaultValue: "Image", bundle: .module)
        case .text:
            String(localized: "terminal.artifact.gallery.kind.text", defaultValue: "Text document", bundle: .module)
        case .binary:
            String(localized: "terminal.artifact.gallery.kind.binary", defaultValue: "Binary file", bundle: .module)
        case .directory:
            String(localized: "terminal.artifact.gallery.kind.directory", defaultValue: "Folder", bundle: .module)
        }
    }

    private var symbolTint: Color {
        switch artifact.kind {
        case .image, .binary:
            .secondary
        case .text, .directory:
            .blue
        }
    }

    private var symbolName: String {
        switch artifact.kind {
        case .image:
            return "photo"
        case .text:
            return "doc.text"
        case .binary:
            return "doc.fill"
        case .directory:
            return "folder"
        }
    }

    private static let thumbnailDimension = 256
}
#endif
