import Foundation

struct FileSearchFileGroup: Equatable {
    let path: String
    let relativePath: String
    let filename: String
    /// Parent directory of `relativePath`, with no trailing slash. Empty when
    /// the file sits at the workspace root.
    let directoryDisplay: String
    let hits: [FileSearchResult]
}

enum FileSearchGrouper {
    static func group(_ results: [FileSearchResult]) -> [FileSearchFileGroup] {
        if results.isEmpty { return [] }

        // Pre-size for the worst case (every hit a new file). Over-estimates
        // when most hits cluster, but a single `reserveCapacity` is cheaper
        // than the 2–3 rehashes a streaming dictionary would do.
        var hitsByPath: [String: [FileSearchResult]] = [:]
        hitsByPath.reserveCapacity(results.count)
        var pathOrder: [String] = []
        pathOrder.reserveCapacity(results.count)

        for result in results {
            let path = result.relativePath
            if hitsByPath[path] == nil {
                pathOrder.append(path)
            }
            hitsByPath[path, default: []].append(result)
        }

        var groups: [FileSearchFileGroup] = []
        groups.reserveCapacity(pathOrder.count)
        for relativePath in pathOrder {
            let hits = hitsByPath[relativePath] ?? []
            let absolutePath = hits.first?.path ?? relativePath
            let nsRelative = relativePath as NSString
            let filename = nsRelative.lastPathComponent
            let parent = nsRelative.deletingLastPathComponent
            groups.append(FileSearchFileGroup(
                path: absolutePath,
                relativePath: relativePath,
                filename: filename,
                directoryDisplay: parent,
                hits: hits
            ))
        }
        return groups
    }
}
