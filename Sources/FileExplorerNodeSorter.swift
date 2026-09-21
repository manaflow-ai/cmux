import Foundation

struct FileExplorerNodeSorter {
    let options: FileExplorerSortOptions

    func sorted(_ nodes: [FileExplorerNode]) -> [FileExplorerNode] {
        nodes.sorted { lhs, rhs in
            isOrderedBefore(lhs, rhs)
        }
    }

    private func isOrderedBefore(
        _ lhs: FileExplorerNode,
        _ rhs: FileExplorerNode
    ) -> Bool {
        switch options.key {
        case .name:
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return orderedByName(lhs, rhs, order: options.order)
        case .dateCreated:
            if let result = orderedByDate(lhs.creationDate, rhs.creationDate, order: options.order) {
                return result
            }
            return orderedByFallback(lhs, rhs)
        case .dateModified:
            if let result = orderedByDate(lhs.modificationDate, rhs.modificationDate, order: options.order) {
                return result
            }
            return orderedByFallback(lhs, rhs)
        }
    }

    private func orderedByDate(_ lhs: Date?, _ rhs: Date?, order: FileExplorerSortOrder) -> Bool? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs:
            return order == .ascending ? lhs < rhs : lhs > rhs
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return nil
        }
    }

    private func orderedByFallback(_ lhs: FileExplorerNode, _ rhs: FileExplorerNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        return orderedByName(lhs, rhs, order: .ascending)
    }

    private func orderedByName(
        _ lhs: FileExplorerNode,
        _ rhs: FileExplorerNode,
        order: FileExplorerSortOrder
    ) -> Bool {
        switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
        case .orderedAscending:
            return order == .ascending
        case .orderedDescending:
            return order == .descending
        case .orderedSame:
            switch lhs.path.localizedCaseInsensitiveCompare(rhs.path) {
            case .orderedAscending:
                return order == .ascending
            case .orderedDescending:
                return order == .descending
            case .orderedSame:
                return false
            }
        }
    }
}
