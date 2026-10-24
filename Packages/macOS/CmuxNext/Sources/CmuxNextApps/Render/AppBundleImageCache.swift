import AppKit

/// Decoded bundle images, keyed by absolute path. Paths are validated to
/// stay inside the bundle directory. Owned by the ``AppsClient`` (one per
/// app supervisor connection, so one for the App): every mount of the
/// client shares it (``AppMount/bundleImages``), and its views read it
/// from `EnvironmentValues.appBundleImages`.
@MainActor
final class AppBundleImageCache {
    private var images: [String: NSImage] = [:]

    init() {}

    func image(path: String?, in directory: URL?) -> NSImage? {
        guard let path, let directory, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let url = directory.appending(path: path).standardizedFileURL
        guard url.path.hasPrefix(directory.standardizedFileURL.path) else { return nil }
        if let cached = images[url.path] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        if images.count > 64 { images.removeAll() }
        images[url.path] = image
        return image
    }
}
