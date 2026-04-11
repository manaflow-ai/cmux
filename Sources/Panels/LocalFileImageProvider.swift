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

    @State private var outcome: LoadOutcome?

    private enum LoadOutcome {
        case loaded(URL, NSImage)
        case failed(URL)
    }

    var body: some View {
        switch url.map(LocalFileImageLoader.classify) {
        case .remote(let remoteURL)?:
            // Delegate to the upstream default so remote images keep their
            // original shrink-only sizing via swift-markdown-ui's ResizeToFit.
            DefaultImageProvider().makeImage(url: remoteURL)

        case .local(let fileURL)?:
            localStateView(for: fileURL)
                .task(id: fileURL) { await load(fileURL: fileURL) }

        case .unsupported?, nil:
            placeholder
        }
    }

    @ViewBuilder
    private func localStateView(for fileURL: URL) -> some View {
        // Gate the render on a URL match so a stale outcome from a previous
        // `fileURL` can't flash through during a URL transition before the
        // new load task starts.
        if case .loaded(let url, let image) = outcome, url == fileURL {
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
        } else if case .failed(let url) = outcome, url == fileURL {
            placeholder
        } else {
            Color.clear
        }
    }

    private func load(fileURL: URL) async {
        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            if Task.isCancelled { return nil }
            let cacheKey = LocalFileImageCache.key(for: fileURL)
            if Task.isCancelled { return nil }
            if let cacheKey, let cached = LocalFileImageCache.shared.object(forKey: cacheKey) {
                return cached
            }
            if Task.isCancelled { return nil }
            guard let image = NSImage(contentsOf: fileURL) else { return nil }
            if let cacheKey {
                LocalFileImageCache.shared.setObject(image, forKey: cacheKey)
            }
            return image
        }

        // Forward the parent `.task(id:)` cancellation into the detached task
        // so an in-flight stat + NSImage load can short-circuit when the view
        // moves on to a new URL instead of running to completion.
        let decoded = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        if Task.isCancelled { return }

        outcome = decoded.map { .loaded(fileURL, $0) } ?? .failed(fileURL)
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
