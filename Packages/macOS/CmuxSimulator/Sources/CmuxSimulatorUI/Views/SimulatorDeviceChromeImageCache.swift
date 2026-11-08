import AppKit

@MainActor
final class SimulatorDeviceChromeImageCache {
    typealias Loader = (URL) -> NSImage?

    private let loader: Loader
    private var images: [URL: NSImage] = [:]
    private var missingURLs: Set<URL> = []

    init(loader: @escaping Loader = { NSImage(contentsOf: $0) }) {
        self.loader = loader
    }

    func image(at url: URL?) -> NSImage? {
        guard let url, !missingURLs.contains(url) else { return nil }
        if let image = images[url] { return image }
        guard let image = loader(url) else {
            missingURLs.insert(url)
            return nil
        }
        images[url] = image
        return image
    }

    func removeAll() {
        images.removeAll()
        missingURLs.removeAll()
    }
}
