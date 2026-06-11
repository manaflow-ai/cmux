import Foundation

/// Locates the highest-resolution `AppIcon` image file inside a project tree.
// FileManager is Apple-documented thread-safe; this struct holds no other state.
struct AppIconImageLocator: @unchecked Sendable {
    private let fileManager: FileManager

    /// Creates a locator. Inject a `FileManager` for testing.
    init(fileManager: FileManager) { self.fileManager = fileManager }

    /// Returns the URL of the largest rendered icon in the project's `AppIcon`
    /// asset, or `nil` when no usable `*.appiconset` is found.
    ///
    /// Candidates are tried in preference order and the first one that yields a
    /// usable image wins, so an empty or image-less `*.appiconset` never shadows
    /// a populated one elsewhere in the tree.
    func bestIconURL(inProjectRoot root: URL) -> URL? {
        for set in rankedAppIconSetURLs(inRoot: root) {
            if let url = largestImageURL(inAppIconSet: set) { return url }
        }
        return nil
    }

    private func rankedAppIconSetURLs(inRoot root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var candidates: [URL] = []
        for case let url as URL in walker where url.pathExtension == "appiconset" {
            candidates.append(url)
        }
        // Prefer the set literally named "AppIcon"; then the shallowest path; then
        // a stable lexicographic tie-break so selection is deterministic when two
        // sets are otherwise equal (e.g. iOS vs. Mac targets at the same depth).
        return candidates.sorted { lhs, rhs in
            let lhsNamed = lhs.deletingPathExtension().lastPathComponent == "AppIcon"
            let rhsNamed = rhs.deletingPathExtension().lastPathComponent == "AppIcon"
            if lhsNamed != rhsNamed { return lhsNamed }
            if lhs.pathComponents.count != rhs.pathComponents.count {
                return lhs.pathComponents.count < rhs.pathComponents.count
            }
            return lhs.path < rhs.path
        }
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
