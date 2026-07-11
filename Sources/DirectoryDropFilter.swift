import Foundation

/// Filters dragged URLs down to existing directories. Pure and injectable so the
/// folders-only rule is unit-testable with no filesystem access.
enum DirectoryDropFilter {
    static func directories(
        among urls: [URL],
        isDirectory: (URL) -> Bool = DirectoryDropFilter.fileSystemIsDirectory
    ) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let path = url.path
            if seen.contains(path) { continue }
            if !isDirectory(url) { continue }
            seen.insert(path)
            result.append(url)
        }
        return result
    }

    static func fileSystemIsDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}
