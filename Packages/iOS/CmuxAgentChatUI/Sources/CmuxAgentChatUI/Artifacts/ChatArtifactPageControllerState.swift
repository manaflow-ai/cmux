import Foundation

/// Pure ordering and completed-selection state for the UIKit artifact pager.
struct ChatArtifactPageControllerState: Equatable, Sendable {
    private(set) var paths: [String]
    private(set) var selectedPath: String

    init(paths: [String], selectedPath: String) {
        self.paths = Self.unique(paths)
        self.selectedPath = selectedPath
        normalizeSelection()
    }

    @discardableResult
    mutating func update(paths: [String], selectedPath: String) -> Bool {
        let uniquePaths = Self.unique(paths)
        let didChangePaths = self.paths != uniquePaths
        self.paths = uniquePaths
        self.selectedPath = selectedPath
        normalizeSelection()
        return didChangePaths
    }

    mutating func completeTransition(to path: String) -> Bool {
        guard paths.contains(path), path != selectedPath else { return false }
        selectedPath = path
        return true
    }

    func path(before path: String) -> String? {
        guard let index = paths.firstIndex(of: path), index > paths.startIndex else {
            return nil
        }
        return paths[paths.index(before: index)]
    }

    func path(after path: String) -> String? {
        guard let index = paths.firstIndex(of: path),
              paths.index(after: index) < paths.endIndex else {
            return nil
        }
        return paths[paths.index(after: index)]
    }

    func isForwardTransition(from source: String?, to destination: String) -> Bool {
        guard let source,
              let sourceIndex = paths.firstIndex(of: source),
              let destinationIndex = paths.firstIndex(of: destination) else {
            return true
        }
        return destinationIndex >= sourceIndex
    }

    private mutating func normalizeSelection() {
        if !paths.contains(selectedPath), let firstPath = paths.first {
            selectedPath = firstPath
        }
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }
}
