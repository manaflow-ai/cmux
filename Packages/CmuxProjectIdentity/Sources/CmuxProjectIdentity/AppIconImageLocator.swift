import Foundation

/// Locates the highest-resolution `AppIcon` image file inside a project tree.
struct AppIconImageLocator {
    private let fileManager: FileManager

    /// Creates a locator. Inject a `FileManager` for testing.
    init(fileManager: FileManager) { self.fileManager = fileManager }

    /// Returns the URL of the largest rendered icon in the project's `AppIcon`
    /// asset, or `nil` when no usable `*.appiconset` is found.
    func bestIconURL(inProjectRoot root: URL) -> URL? {
        guard let set = appIconSetURL(inRoot: root) else { return nil }
        return largestImageURL(inAppIconSet: set)
    }

    private func appIconSetURL(inRoot root: URL) -> URL? {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        var candidates: [URL] = []
        for case let url as URL in walker where url.pathExtension == "appiconset" {
            candidates.append(url)
        }
        // Prefer the set literally named "AppIcon"; then shallowest path.
        return candidates
            .sorted { lhs, rhs in
                let lhsNamed = lhs.deletingPathExtension().lastPathComponent == "AppIcon"
                let rhsNamed = rhs.deletingPathExtension().lastPathComponent == "AppIcon"
                if lhsNamed != rhsNamed { return lhsNamed }
                return lhs.pathComponents.count < rhs.pathComponents.count
            }
            .first
    }

    private func largestImageURL(inAppIconSet set: URL) -> URL? {
        let contentsURL = set.appendingPathComponent("Contents.json")
        guard let data = try? Data(contentsOf: contentsURL),
              let manifest = try? JSONDecoder().decode(AppIconManifest.self, from: data)
        else { return nil }
        let best = manifest.images
            .compactMap { entry -> (URL, Double)? in
                guard let filename = entry.filename, !filename.isEmpty else { return nil }
                let url = set.appendingPathComponent(filename)
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                return (url, entry.renderedPixelWidth)
            }
            .max { $0.1 < $1.1 }
        return best?.0
    }
}

/// Minimal decode of an `.appiconset` `Contents.json`.
private struct AppIconManifest: Decodable {
    let images: [Entry]
    struct Entry: Decodable {
        let size: String?
        let scale: String?
        let filename: String?
        /// Rendered width in pixels = point size × scale (e.g. 1024×1 = 1024).
        var renderedPixelWidth: Double {
            let points = Double(size?.split(separator: "x").first.map(String.init) ?? "") ?? 0
            let factor = Double(scale?.replacingOccurrences(of: "x", with: "") ?? "1") ?? 1
            return points * factor
        }
    }
}
