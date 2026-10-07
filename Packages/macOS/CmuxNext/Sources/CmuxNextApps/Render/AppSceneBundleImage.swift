import AppKit
import SwiftUI

/// `Image(src)`: a file inside the app bundle (never the network).
struct AppSceneBundleImage: View {
    let path: String?
    @Environment(\.appBundleDirectory) private var directory

    var body: some View {
        if let image = AppBundleImageCache.shared.image(path: path, in: directory) {
            Image(nsImage: image).resizable().scaledToFit()
        }
    }
}

/// Decoded bundle images, keyed by absolute path. Paths are validated to
/// stay inside the bundle directory.
@MainActor
final class AppBundleImageCache {
    static let shared = AppBundleImageCache()
    private var images: [String: NSImage] = [:]

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
