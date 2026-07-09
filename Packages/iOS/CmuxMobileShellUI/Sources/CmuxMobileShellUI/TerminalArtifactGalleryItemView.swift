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

    var body: some View {
        Button(action: open) {
            switch layout {
            case .list:
                listContent
            case .grid:
                gridContent
            }
        }
        .buttonStyle(.plain)
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
        return VStack(alignment: .leading, spacing: 7) {
            preview
                .aspectRatio(1, contentMode: .fit)

            Text(artifact.displayName)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(height: 38, alignment: .topLeading)

            Text(metadata ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .opacity(metadata == nil ? 0 : 1)
                .frame(height: 28, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))

            if let thumbnail,
               let image = UIImage(data: thumbnail.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: layout == .grid ? 34 : 22, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
    }

    private var metadataText: String? {
        var components: [String] = []
        if let modifiedAt = artifact.modifiedAt {
            components.append(modifiedAt.formatted(
                .dateTime.month(.twoDigits).day(.twoDigits).year()
            ))
        }
        if let size = artifact.size {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = .useAll
            components.append(formatter.string(fromByteCount: max(0, size)))
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
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
