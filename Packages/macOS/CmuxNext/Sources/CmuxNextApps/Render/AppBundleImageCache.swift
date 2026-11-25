import AppKit

/// Decoded images for `Image(src)`: a file inside the app bundle (never the network), keyed by
/// absolute path and validated to stay inside the bundle directory, or a small inline
/// `data:image/png;base64,` or `data:image/jpeg;base64,` URL (at most ``maxDataURLBytes``), such as the
/// artwork `media.get` answers. A data URL reads nothing outside the app's own message, so it
/// reaches no file and no network; any other scheme draws nothing.
@MainActor
final class AppBundleImageCache {
    static let shared = AppBundleImageCache()
    /// Largest inline image URL decoded; a bigger one draws nothing.
    static let maxDataURLBytes = 256 * 1024 + 32
    private static let dataPrefixes = ["data:image/png;base64,", "data:image/jpeg;base64,"]
    private var images: [String: NSImage] = [:]
    private var inline: [String: NSImage] = [:]

    func image(path: String?, in directory: URL?) -> NSImage? {
        if let path, path.hasPrefix("data:") { return inlineImage(path) }
        guard let path, let directory, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let url = directory.appending(path: path).standardizedFileURL
        guard url.path.hasPrefix(directory.standardizedFileURL.path) else { return nil }
        if let cached = images[url.path] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        if images.count > 64 { images.removeAll() }
        images[url.path] = image
        return image
    }

    /// A PNG or JPEG data URL decoded, cached by the URL (a few entries: a player's track changes).
    private func inlineImage(_ url: String) -> NSImage? {
        guard url.utf8.count <= Self.maxDataURLBytes,
              let prefix = Self.dataPrefixes.first(where: { url.hasPrefix($0) }) else { return nil }
        if let cached = inline[url] { return cached }
        guard let data = Data(base64Encoded: String(url.dropFirst(prefix.count))), let image = NSImage(data: data),
              image.isValid else { return nil }
        if inline.count >= 8 { inline.removeAll() }
        inline[url] = image
        return image
    }
}
