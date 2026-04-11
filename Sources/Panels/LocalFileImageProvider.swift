import AppKit
import MarkdownUI
import SwiftUI

/// swift-markdown-ui image provider that renders local files in addition to
/// the remote-only behavior of the default provider.
struct LocalFileImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        LocalFileImageView(url: url)
    }
}

private struct LocalFileImageView: View {
    let url: URL?

    @State private var loadState: LoadState = .idle

    private enum LoadState {
        case idle
        case loaded(NSImage)
        case failed
    }

    var body: some View {
        switch url.map(LocalFileImageLoader.classify) {
        case .remote(let remoteURL)?:
            // Delegate to the upstream default so remote images keep their
            // original shrink-only sizing via swift-markdown-ui's ResizeToFit.
            DefaultImageProvider().makeImage(url: remoteURL)

        case .local(let fileURL)?:
            localStateView
                .task(id: fileURL) { await load(fileURL: fileURL) }

        case .unsupported?, nil:
            placeholder
        }
    }

    @ViewBuilder
    private var localStateView: some View {
        switch loadState {
        case .loaded(let image):
            // Match upstream's shrink-only layout: render at natural size
            // when it fits, otherwise scale down proportionally.
            Image(nsImage: image)
                .resizable()
                .aspectRatio(image.size, contentMode: .fit)
                .frame(
                    maxWidth: image.size.width,
                    maxHeight: image.size.height,
                    alignment: .leading
                )
        case .failed:
            placeholder
        case .idle:
            Color.clear
        }
    }

    private func load(fileURL: URL) async {
        loadState = .idle

        let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let cacheKey = LocalFileImageCache.key(for: fileURL)
            if let cacheKey, let cached = LocalFileImageCache.shared.object(forKey: cacheKey) {
                return cached
            }
            guard let image = NSImage(contentsOf: fileURL) else { return nil }
            if let cacheKey {
                LocalFileImageCache.shared.setObject(image, forKey: cacheKey)
            }
            return image
        }.value

        if Task.isCancelled { return }

        loadState = loaded.map(LoadState.loaded) ?? .failed
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.system(size: 20))
                .foregroundColor(.secondary)
            Text(String(
                localized: "markdown.image.missing.label",
                defaultValue: "Image not found"
            ))
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(8)
    }
}

/// Shared cache keyed by path + file mtime. The mtime qualifier ensures that
/// a remounted image view (e.g. panel closed and reopened after the file was
/// edited) hits a cache miss and reloads rather than reusing a stale bitmap
/// under the same path. Same-URL re-renders within a single mounted view are
/// governed by SwiftUI's `.task(id:)` identity and don't re-stat.
enum LocalFileImageCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.name = "cmux.markdown.localFileImage"
        cache.countLimit = 64
        return cache
    }()

    static func key(for fileURL: URL) -> NSString? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let mtime = attrs?[.modificationDate] as? Date else {
            return nil
        }
        return "\(fileURL.path)|\(mtime.timeIntervalSinceReferenceDate)" as NSString
    }
}
