import Foundation

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
