import Foundation

public enum FileExtensionOpenBehaviorSettings {
    public static let key = "fileExtensionOpeners"
    public static let didChangeNotification = Notification.Name("cmux.fileExtensionOpenersDidChange")
    public static let defaultValue = FileExtensionOpenBehavior.defaultOpeners

    public static func openers(defaults: UserDefaults = .standard) -> [String: FileExtensionOpenBehavior] {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        guard let stored = defaults.dictionary(forKey: key) else { return defaultValue }

        var result: [String: FileExtensionOpenBehavior] = [:]
        for (rawExtension, rawBehavior) in stored {
            guard let normalizedExtension = FileExtensionOpenBehavior.normalizedExtension(rawExtension),
                  let rawBehavior = rawBehavior as? String,
                  let behavior = FileExtensionOpenBehavior(rawValue: rawBehavior) else {
                continue
            }
            result[normalizedExtension] = behavior
        }
        return result
    }

    public static func behavior(forPath path: String, defaults: UserDefaults = .standard) -> FileExtensionOpenBehavior? {
        let ext = (path as NSString).pathExtension
        guard let normalizedExtension = FileExtensionOpenBehavior.normalizedExtension(ext) else {
            return nil
        }
        return openers(defaults: defaults)[normalizedExtension]
    }

    public static func setOpeners(
        _ openers: [String: FileExtensionOpenBehavior],
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        var normalized: [String: String] = [:]
        for (rawExtension, behavior) in openers {
            guard let normalizedExtension = FileExtensionOpenBehavior.normalizedExtension(rawExtension) else { continue }
            normalized[normalizedExtension] = behavior.rawValue
        }
        defaults.set(normalized, forKey: key)
        notifyDidChange(notificationCenter: notificationCenter)
    }

    public static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}
