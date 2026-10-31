import Foundation

/// Persists the file explorer sort options in `UserDefaults` and announces changes so every open explorer re-sorts.
struct FileExplorerSortSettings {
    /// `UserDefaults` key for the sort key; also the `cmux.json` path `fileExplorer.sortBy`.
    static let sortKeyKey = "fileExplorer.sortBy"
    /// `UserDefaults` key for the sort order; also the `cmux.json` path `fileExplorer.sortOrder`.
    static let sortOrderKey = "fileExplorer.sortOrder"
    /// Posted after the stored options change, from the header menu or from a `cmux.json` reload.
    static let didChangeNotification = Notification.Name("cmux.fileExplorerSortSettingsDidChange")

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    /// Creates settings backed by `defaults` that post to `notificationCenter`.
    init(defaults: UserDefaults, notificationCenter: NotificationCenter) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    /// Reads the stored options, falling back to ``FileExplorerSortOptions/defaultValue`` for missing values.
    func resolvedOptions() -> FileExplorerSortOptions {
        FileExplorerSortOptions(
            key: FileExplorerSortKey(resolvingRawValue: defaults.string(forKey: Self.sortKeyKey)),
            order: FileExplorerSortOrder(resolvingRawValue: defaults.string(forKey: Self.sortOrderKey))
        )
    }

    /// Stores `options` and posts ``didChangeNotification``.
    func setOptions(_ options: FileExplorerSortOptions) {
        defaults.set(options.key.rawValue, forKey: Self.sortKeyKey)
        defaults.set(options.order.rawValue, forKey: Self.sortOrderKey)
        notifyDidChange()
    }

    /// Posts ``didChangeNotification`` on this instance's notification center.
    func notifyDidChange() {
        Self.notifyDidChange(notificationCenter: notificationCenter)
    }

    /// Posts ``didChangeNotification`` on `notificationCenter`, for callers that write the defaults directly.
    static func notifyDidChange(notificationCenter: NotificationCenter) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}
