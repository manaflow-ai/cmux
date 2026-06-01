import Foundation

/// UserDefaults-backed storage helpers for per-extension file opener behavior.
public enum FileExtensionOpenBehaviorSettings {
    /// UserDefaults key storing normalized extension-to-behavior raw values.
    public static let key = "fileExtensionOpeners"
    /// Posted after this helper writes the opener map.
    public static let didChangeNotification = Notification.Name("cmux.fileExtensionOpenersDidChange")
    /// Product defaults applied before user overrides.
    public static let defaultValue = FileExtensionOpenBehavior.defaultOpeners

    /// Reads normalized opener mappings from `defaults`.
    ///
    /// Built-in defaults are preserved, and valid stored entries override them.
    /// Invalid stored entries are skipped.
    public static func openers(defaults: UserDefaults) -> [String: FileExtensionOpenBehavior] {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        guard let stored = defaults.dictionary(forKey: key) else { return defaultValue }

        var storedOpeners: [String: FileExtensionOpenBehavior] = [:]
        for (rawExtension, rawBehavior) in stored {
            guard let normalizedExtension = FileExtensionOpenBehavior.normalizedExtension(rawExtension),
                  let rawBehavior = rawBehavior as? String,
                  let behavior = FileExtensionOpenBehavior(rawValue: rawBehavior) else {
                continue
            }
            storedOpeners[normalizedExtension] = behavior
        }
        return effectiveOpeners(from: storedOpeners)
    }

    /// Returns the opener behavior for `path`'s extension, if one is configured.
    public static func behavior(forPath path: String, defaults: UserDefaults) -> FileExtensionOpenBehavior? {
        let ext = (path as NSString).pathExtension
        guard let normalizedExtension = FileExtensionOpenBehavior.normalizedExtension(ext) else {
            return nil
        }
        return openers(defaults: defaults)[normalizedExtension]
    }

    /// Writes normalized opener mappings and posts ``didChangeNotification``.
    ///
    /// Entries matching built-in defaults are pruned. Store ``FileExtensionOpenBehavior/automatic``
    /// for a built-in extension to explicitly opt out of that built-in route.
    public static func setOpeners(
        _ openers: [String: FileExtensionOpenBehavior],
        defaults: UserDefaults,
        notificationCenter: NotificationCenter
    ) {
        var normalized: [String: String] = [:]
        for (rawExtension, behavior) in openers {
            guard let normalizedExtension = FileExtensionOpenBehavior.normalizedExtension(rawExtension) else { continue }
            guard FileExtensionOpenBehavior.defaultOpeners[normalizedExtension] != behavior else { continue }
            normalized[normalizedExtension] = behavior.rawValue
        }
        defaults.set(normalized, forKey: key)
        notifyDidChange(notificationCenter: notificationCenter)
    }

    /// Normalizes `openers` and overlays them onto the built-in defaults.
    public static func effectiveOpeners(
        from openers: [String: FileExtensionOpenBehavior]
    ) -> [String: FileExtensionOpenBehavior] {
        var result = defaultValue
        for (rawExtension, behavior) in openers {
            guard let normalizedExtension = FileExtensionOpenBehavior.normalizedExtension(rawExtension) else { continue }
            result[normalizedExtension] = behavior
        }
        return result
    }

    /// Posts ``didChangeNotification`` on `notificationCenter`.
    public static func notifyDidChange(notificationCenter: NotificationCenter) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}
