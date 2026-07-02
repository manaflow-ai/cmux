import Foundation

// MARK: - File Explorer Sort Model

enum FileExplorerSortKey: String, CaseIterable, Sendable {
    case name
    case dateCreated
    case dateModified

    init(resolvingRawValue raw: String?) {
        self = raw.flatMap { Self(rawValue: $0) } ?? .name
    }

    var localizedTitle: String {
        switch self {
        case .name:
            return String(localized: "fileExplorer.sort.key.name", defaultValue: "Name")
        case .dateCreated:
            return String(localized: "fileExplorer.sort.key.dateCreated", defaultValue: "Date Created")
        case .dateModified:
            return String(localized: "fileExplorer.sort.key.dateModified", defaultValue: "Date Modified")
        }
    }
}

enum FileExplorerSortOrder: String, CaseIterable, Sendable {
    case ascending
    case descending

    init(resolvingRawValue raw: String?) {
        self = raw.flatMap { Self(rawValue: $0) } ?? .ascending
    }

    var localizedTitle: String {
        switch self {
        case .ascending:
            return String(localized: "fileExplorer.sort.order.ascending", defaultValue: "Ascending")
        case .descending:
            return String(localized: "fileExplorer.sort.order.descending", defaultValue: "Descending")
        }
    }
}

struct FileExplorerSortOptions: Equatable, Sendable {
    let key: FileExplorerSortKey
    let order: FileExplorerSortOrder

    static let defaultValue = FileExplorerSortOptions(key: .name, order: .ascending)
}

struct FileExplorerSortSettings {
    static let sortKeyKey = "fileExplorer.sortBy"
    static let sortOrderKey = "fileExplorer.sortOrder"
    static let didChangeNotification = Notification.Name("cmux.fileExplorerSortSettingsDidChange")

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(defaults: UserDefaults, notificationCenter: NotificationCenter) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    func resolvedOptions() -> FileExplorerSortOptions {
        FileExplorerSortOptions(
            key: FileExplorerSortKey(resolvingRawValue: defaults.string(forKey: Self.sortKeyKey)),
            order: FileExplorerSortOrder(resolvingRawValue: defaults.string(forKey: Self.sortOrderKey))
        )
    }

    func setOptions(_ options: FileExplorerSortOptions) {
        defaults.set(options.key.rawValue, forKey: Self.sortKeyKey)
        defaults.set(options.order.rawValue, forKey: Self.sortOrderKey)
        notifyDidChange()
    }

    func notifyDidChange() {
        notificationCenter.post(name: Self.didChangeNotification, object: nil)
    }
}

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
