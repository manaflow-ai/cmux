import AppKit
import SwiftUI
import MarkdownUI

struct MarkdownPanelImageProvider: ImageProvider {
    let markdownDirectoryURL: URL

    func makeImage(url: URL?) -> some View {
        MarkdownPanelImageView(url: Self.resolvedImageURL(url, markdownDirectoryURL: markdownDirectoryURL))
    }

    static func resolvedImageURL(from source: String, markdownDirectoryURL: URL) -> URL? {
        guard let url = URL(string: source, relativeTo: markdownDirectoryURL) else { return nil }
        return resolvedImageURL(url, markdownDirectoryURL: markdownDirectoryURL)
    }

    static func resolvedImageURL(_ url: URL?, markdownDirectoryURL: URL) -> URL? {
        guard let url else { return nil }
        let absoluteURL = url.absoluteURL
        return absoluteURL.isFileURL ? absoluteURL.standardizedFileURL : absoluteURL
    }
}

struct MarkdownPanelInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        if url.isFileURL {
            let data = try await MarkdownPanelLocalImageLoader.data(contentsOf: url)
            guard let image = await MainActor.run(body: { NSImage(data: data) }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return await MainActor.run(body: { Image(nsImage: image) })
        }
        let provider: DefaultInlineImageProvider = .default
        return try await provider.image(with: url, label: label)
    }
}

enum MarkdownPanelLocalImageLoader {
    static func data(contentsOf url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url)
        }.value
    }
}

private struct MarkdownPanelImageView: View {
    let url: URL?
    @State private var loadedLocalImage: NSImage?
    @State private var loadedLocalImageURL: URL?

    var body: some View {
        if let url {
            if url.isFileURL {
                localImage(url)
            } else {
                remoteImage(url)
            }
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private func localImage(_ url: URL) -> some View {
        Group {
            if loadedLocalImageURL == url, let loadedLocalImage {
                fittedImage(Image(nsImage: loadedLocalImage))
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: url) {
            await loadLocalImage(url)
        }
    }

    private func remoteImage(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                fittedImage(image)
            case .empty, .failure:
                Color.clear.frame(width: 0, height: 0)
            @unknown default:
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    private func fittedImage(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func loadLocalImage(_ url: URL) async {
        loadedLocalImageURL = url
        loadedLocalImage = nil

        guard let data = try? await MarkdownPanelLocalImageLoader.data(contentsOf: url),
              loadedLocalImageURL == url else { return }
        loadedLocalImage = NSImage(data: data)
    }
}
