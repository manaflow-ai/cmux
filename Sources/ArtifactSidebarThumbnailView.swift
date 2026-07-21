import AppKit
import CmuxArtifacts
import QuickLookThumbnailing
import SwiftUI

/// Small Quick Look thumbnail used for image and video artifact rows.
struct ArtifactSidebarThumbnailView: View {
    let fileURL: URL
    let kind: ArtifactFileKind?
    let isDirectory: Bool

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: symbolName)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(.rect(cornerRadius: 4))
        .task(id: fileURL) {
            await loadThumbnailIfNeeded()
        }
    }

    private var symbolName: String {
        if isDirectory { return "folder" }
        switch kind {
        case .image: return "photo"
        case .video: return "film"
        case .markdown: return "doc.richtext"
        case .html: return "globe"
        case .patch: return "doc.badge.gearshape"
        case .text: return "doc.text"
        case .other, .none: return "doc"
        }
    }

    @MainActor
    private func loadThumbnailIfNeeded() async {
        guard kind == .image || kind == .video else {
            thumbnail = nil
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 48, height: 48),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: [.thumbnail, .icon]
        )
        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        guard !Task.isCancelled else { return }
        thumbnail = representation?.nsImage
    }
}
