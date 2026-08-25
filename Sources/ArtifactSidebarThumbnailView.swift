import AppKit
import CmuxArtifacts
import QuickLookThumbnailing
import SwiftUI

/// Small Quick Look thumbnail used for image and video artifact rows.
struct ArtifactSidebarThumbnailView: View {
    let fileURL: URL
    let artifactRoot: URL?
    let kind: ArtifactFileKind?
    let isDirectory: Bool
    let revision: ArtifactSidebarFileRevision?

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
        .task(id: revision) {
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
        thumbnail = nil
        guard kind == .image || kind == .video else {
            return
        }
        let openedFile: ArtifactSidebarFileAccess.OpenedFile?
        let temporaryURL: URL?
        if let artifactRoot {
            openedFile = ArtifactSidebarFileAccess().openedFile(
                for: fileURL,
                artifactRoot: artifactRoot
            )
            guard let openedFile else { return }
            temporaryURL = await openedFile.makeTemporaryPreviewURLAsync()
            guard let temporaryURL else { return }
        } else {
            openedFile = nil
            temporaryURL = nil
        }
        defer {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: temporaryURL ?? openedFile?.sourceURL ?? fileURL,
            size: CGSize(width: 48, height: 48),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: [.thumbnail, .icon]
        )
        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        guard !Task.isCancelled else { return }
        thumbnail = representation?.nsImage
    }
}
