import Foundation

extension CMUXCLI {
    func diffViewerBundledAssetRelativePaths(in sourceDirectory: URL) throws -> [String] {
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
