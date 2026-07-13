import Foundation

/// Chrome refuses to load unpacked extensions from read-only locations (it
/// writes computed IDs and script caches next to profile state), so bundled
/// extension directories are copied into a writable staging area under the
/// root cache path before being handed to --load-extension.
enum CEFExtensionStager {
    static func stage(_ extensionDirectories: [URL], rootCachePath: URL) -> [URL] {
        let fm = FileManager.default
        let stagingRoot = rootCachePath.appendingPathComponent("CEFKitExtensions", isDirectory: true)
        try? fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        var staged: [URL] = []
        for source in extensionDirectories {
            guard fm.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
                continue
            }
            let destination = stagingRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: source, to: destination)
                staged.append(destination)
            } catch {
                FileHandle.standardError.write(
                    Data("CEFKit: failed to stage extension \(source.lastPathComponent): \(error)\n".utf8)
                )
            }
        }
        return staged
    }
}
