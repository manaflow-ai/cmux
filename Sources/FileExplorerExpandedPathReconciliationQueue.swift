import Foundation

/// Drains expanded File Explorer paths parent-first without globally sorting
/// the potentially large expanded-path set.
struct FileExplorerExpandedPathReconciliationQueue {
    private var pathsByDepth: [[String]]
    private var depthIndex = 0
    private var pathIndex = 0
    private(set) var count: Int

    init(paths: Set<String> = []) {
        var pathsByDepth: [[String]] = []
        for path in paths {
            let depth = path.split(separator: "/").count
            if depth >= pathsByDepth.count {
                pathsByDepth.append(
                    contentsOf: repeatElement([String](), count: depth - pathsByDepth.count + 1)
                )
            }
            pathsByDepth[depth].append(path)
        }
        self.pathsByDepth = pathsByDepth
        self.count = paths.count
    }

    var isEmpty: Bool { count == 0 }

    mutating func removeFirst() -> String? {
        while depthIndex < pathsByDepth.count {
            let paths = pathsByDepth[depthIndex]
            if pathIndex < paths.count {
                let path = paths[pathIndex]
                pathIndex += 1
                count -= 1
                return path
            }
            depthIndex += 1
            pathIndex = 0
        }
        count = 0
        return nil
    }

    mutating func removeAll() {
        pathsByDepth.removeAll(keepingCapacity: false)
        depthIndex = 0
        pathIndex = 0
        count = 0
    }
}
