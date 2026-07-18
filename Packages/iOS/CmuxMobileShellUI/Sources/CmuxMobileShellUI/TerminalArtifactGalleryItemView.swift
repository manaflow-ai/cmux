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

    let artifact: TerminalArtifactGalleryDisplayItem
    let layout: Layout
    let loader: ChatArtifactLoader
    let open: () -> Void

    @State private var thumbnail: ChatArtifactThumbnail?
    @State private var fileActionPresentation: ChatArtifactFileActionPresentation?
    @State private var isFileActionRunning = false
    @State private var showsFileActionError = false
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
        .opacity(artifact.exists ? 1 : 0.5)
        .contextMenu {
            if artifact.kind != .directory {
                Button {
                    shareFile()
                } label: {
                    Label(
                        String(
                            localized: "terminal.artifact.gallery.share",
                            defaultValue: "Share",
                            bundle: .module
                        ),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .disabled(!artifact.exists || isFileActionRunning)
            }
            Button {
                UIPasteboard.general.string = artifact.path
            } label: {
                Label(
                    String(
                        localized: "terminal.artifact.gallery.copy_path",
                        defaultValue: "Copy path",
                        bundle: .module
                    ),
                    systemImage: "link"
                )
            }
            if artifact.kind == .directory {
                Button(action: open) {
                    Label(
                        String(
                            localized: "terminal.artifact.gallery.browse_folder",
                            defaultValue: "Browse folder",
                            bundle: .module
                        ),
                        systemImage: "folder"
                    )
                }
                .disabled(!artifact.exists)
            }
        }
        .chatArtifactFileActionPresentation($fileActionPresentation)
        .alert(
            String(
                localized: "terminal.artifact.gallery.action_failed.title",
                defaultValue: "Couldn't complete action",
                bundle: .module
            ),
            isPresented: $showsFileActionError
        ) {
            Button(String(localized: "terminal.artifact.gallery.ok", defaultValue: "OK", bundle: .module)) {}
        } message: {
            Text(String(
                localized: "terminal.artifact.gallery.action_failed.message",
                defaultValue: "Check the connection to your Mac and try again.",
                bundle: .module
            ))
        }
        .task(id: "\(artifact.path)#\(Self.thumbnailDimension)") {
            guard artifact.kind == .image, artifact.exists else { return }
            thumbnail = try? await loader.thumbnail(
                path: artifact.path,
                maxDimension: Self.thumbnailDimension,
                modifiedAt: artifact.modifiedAt,
                size: artifact.size
            )
        }
    }

    private func shareFile() {
        guard !isFileActionRunning else { return }
        isFileActionRunning = true
        Task {
            do {
                let fileURL = try await ChatArtifactFileActionStore.applicationDefault.materialize(
                    path: artifact.path,
                    loader: loader
                )
                try Task.checkCancellation()
                fileActionPresentation = .share(fileURL)
            } catch is CancellationError {
                // The row disappeared while its file was being prepared.
            } catch {
                showsFileActionError = true
            }
            isFileActionRunning = false
        }
    }

    private var listContent: some View {
        HStack(spacing: 12) {
            preview
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detailText {
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if !artifact.exists {
                missingBadge
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var gridContent: some View {
        let metadata = detailText
        return VStack(alignment: .center, spacing: 7) {
            preview
                .aspectRatio(1, contentMode: .fit)

            // Name + metadata share one top-aligned reserve so the subtitle hugs
            // the title instead of sitting below the name's empty two-line
            // reserve, while cells keep a uniform height.
            VStack(alignment: .center, spacing: 2) {
                Text(artifact.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if artifact.exists {
                    Text(metadata ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .opacity(metadata == nil ? 0 : 1)
                } else {
                    // Missing files have no metadata; the badge takes the
                    // subtitle slot so it sits right under the cell.
                    missingBadge
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: gridNameMinHeight + gridMetadataMinHeight,
                alignment: .top
            )
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
        let glyph = ChatArtifactGalleryClassifier().glyphPresentation(
            for: artifact.kind,
            path: artifact.path
        )
        return Image(systemName: glyph.systemImageName)
            .font(.system(size: layout == .grid ? gridSymbolSize : listSymbolSize, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(glyph.tint.swiftUIColor)
    }

    private var metadataText: String? {
        var components: [String] = []
        if artifact.kind == .directory, let childCount = artifact.childCount {
            components.append(childCountText(childCount))
        }
        if let modifiedAt = artifact.modifiedAt {
            components.append(modifiedAt.formatted(date: .abbreviated, time: .omitted))
        }
        if artifact.kind != .directory, let size = artifact.size {
            components.append(ByteCountFormatter.string(
                fromByteCount: max(0, size),
                countStyle: .file
            ))
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private func childCountText(_ childCount: Int) -> String {
        TerminalArtifactChildCountFormatter().string(
            count: childCount,
            isCapped: artifact.childCountIsCapped
        )
    }

    private var detailText: String? {
        artifact.subtitle ?? metadataText
    }

    private var missingBadge: some View {
        Text(String(
            localized: "terminal.artifact.gallery.missing",
            defaultValue: "No longer on your Mac",
            bundle: .module
        ))
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
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

    private static let thumbnailDimension = 256
}
#endif
