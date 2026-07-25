import Foundation

struct DiffViewerBundledAssetManifest: Decodable {
    struct File: Decodable {
        var logicalPath: String
        var storedPath: String
    }

    var version: Int
    var contentKey: String
    var files: [File]
}

extension CMUXCLI {
    static let diffViewerBundledAssetManifestName = ".cmux-asset-manifest.json"

    func diffViewerBundledAssetManifest(in sourceDirectory: URL) -> DiffViewerBundledAssetManifest? {
        let url = sourceDirectory.appendingPathComponent(
            Self.diffViewerBundledAssetManifestName,
            isDirectory: false
        )
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(DiffViewerBundledAssetManifest.self, from: data),
              manifest.version == 1,
              manifest.contentKey.count == 64,
              manifest.contentKey.allSatisfy({ $0.isHexDigit }),
              !manifest.files.isEmpty,
              Set(manifest.files.map(\.logicalPath)).count == manifest.files.count,
              Set(manifest.files.map(\.storedPath)).count == manifest.files.count,
              manifest.files.allSatisfy({ file in
                  diffViewerBundledAssetManifestPathIsSafe(file.logicalPath) &&
                      diffViewerBundledAssetManifestPathIsSafe(file.storedPath) &&
                      ["js", "mjs"].contains(URL(fileURLWithPath: file.logicalPath).pathExtension) &&
                      (file.storedPath == file.logicalPath || file.storedPath == file.logicalPath + ".deflate")
              }) else {
            return nil
        }
        return manifest
    }

    private func diffViewerBundledAssetManifestPathIsSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    func diffViewerBundledAssetRelativePaths(in sourceDirectory: URL) throws -> [String] {
        if let manifest = diffViewerBundledAssetManifest(in: sourceDirectory) {
            return manifest.files.map(\.logicalPath)
        }
        let rootURL = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CLIError(message: "Failed to enumerate diff viewer assets")
        }

        var relativePaths: Set<String> = []
        for case let fileURL as URL in enumerator {
            let standardized = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            guard standardized.path.hasPrefix(rootURL.path + "/"),
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            var relativePath = String(standardized.path.dropFirst(rootURL.path.count + 1))
            if relativePath.hasSuffix(".deflate") { relativePath.removeLast(".deflate".count) }
            guard ["js", "mjs"].contains(URL(fileURLWithPath: relativePath, isDirectory: false).pathExtension) else {
                continue
            }
            relativePaths.insert(relativePath)
        }
        return relativePaths.sorted()
    }

    func diffViewerBundledAssetFileURL(relativePath: String, in sourceDirectory: URL) throws -> URL {
        let fileManager = FileManager.default
        let deflatedURL = sourceDirectory.appendingPathComponent(relativePath + ".deflate", isDirectory: false)
        if fileManager.fileExists(atPath: deflatedURL.path) { return deflatedURL }
        let rawURL = sourceDirectory.appendingPathComponent(relativePath, isDirectory: false)
        if fileManager.fileExists(atPath: rawURL.path) { return rawURL }
        throw CLIError(message: "Bundled diff viewer asset not found: \(relativePath)")
    }
}
