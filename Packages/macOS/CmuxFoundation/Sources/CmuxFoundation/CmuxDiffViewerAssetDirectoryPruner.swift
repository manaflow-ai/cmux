public import Foundation

/// Removes obsolete local asset directories produced by the diff viewer.
public struct CmuxDiffViewerAssetDirectoryPruner {
    private let fileManager: FileManager

    /// Creates a diff-viewer asset pruner.
    ///
    /// - Parameter fileManager: The file manager used to inspect and remove asset directories.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Removes unreferenced asset directories while preserving recent and in-use versions.
    ///
    /// - Parameters:
    ///   - directory: The diff-viewer root directory containing manifests and the `assets` directory.
    ///   - now: The reference time used to determine whether an asset directory has expired.
    public func prune(
        in directory: URL,
        now: Date = Date()
    ) {
        let assetsDirectory = directory.appendingPathComponent("assets", isDirectory: true)
        guard let assetEntries = try? fileManager.contentsOfDirectory(
            at: assetsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let assetsPath = assetsDirectory.standardizedFileURL.path
        let assetsPrefix = assetsPath.hasSuffix("/") ? assetsPath : assetsPath + "/"
        var referencedDirectories: Set<String> = []
        if let rootEntries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) {
            for manifestURL in rootEntries
                where manifestURL.lastPathComponent.hasPrefix(".manifest-")
                    && manifestURL.pathExtension == "json" {
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let files = manifest["files"] as? [[String: Any]] else {
                    continue
                }
                for file in files {
                    guard file["remote_url"] == nil || file["remote_url"] is NSNull,
                          let path = file["file_path"] as? String else {
                        continue
                    }
                    let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
                    guard standardizedPath.hasPrefix(assetsPrefix) else { continue }
                    let remainder = standardizedPath.dropFirst(assetsPrefix.count)
                    guard let directoryName = remainder.split(separator: "/", maxSplits: 1).first else {
                        continue
                    }
                    referencedDirectories.insert(
                        assetsDirectory.appendingPathComponent(String(directoryName), isDirectory: true)
                            .standardizedFileURL.path
                    )
                }
            }
        }

        let sortedDirectories = assetEntries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey]
            ), values.isDirectory == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        // Keep the newest four versions even without a manifest so a concurrent
        // launch can finish writing its manifest. Older unreferenced versions
        // expire after 24h, with a hard cap of sixteen recent versions.
        for (index, entry) in sortedDirectories.enumerated() {
            guard index >= 4,
                  !referencedDirectories.contains(entry.url.standardizedFileURL.path),
                  index >= 16 || now.timeIntervalSince(entry.date) > 24 * 60 * 60 else {
                continue
            }
            try? fileManager.removeItem(at: entry.url)
        }
    }
}
