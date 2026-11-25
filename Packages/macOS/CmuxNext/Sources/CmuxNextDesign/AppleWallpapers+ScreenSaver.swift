import CmuxNextCompat
public import Foundation

/// The person's screen saver as a background (Leo: "use my screensaver stuff"): the aerial macOS
/// shows when idle, read from the wallpaper store's index
/// (`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`). Its idle choice (or the
/// linked one, when the screen saver follows the wallpaper) names the aerial by its asset id, the
/// name of the movie idleassetsd writes, so it is one of ``videos(fileManager:names:)``.
///
/// ```swift
/// let saver = await AppleWallpapers.system.screenSaver()   // .system(path: ".../<asset id>.mov") or nil
/// ```
extension AppleWallpapers {
    /// The wallpaper store's index macOS writes when a wallpaper or screen saver is chosen.
    public nonisolated static var storeIndex: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// The moving wallpaper that is the screen saver; nil when the screen saver is not an aerial
    /// (a classic `.saver`, a photo slideshow) or the index can't be read. `@concurrent`:
    /// it reads files, never on the main thread.
    /// - Parameters:
    ///   - index: The wallpaper store's index.
    ///   - fileManager: Lists the aerials.
    @concurrent public nonisolated func screenSaver(index: URL = AppleWallpapers.storeIndex, fileManager: FileManager = .default) async -> BackdropSelection? {
        guard let data = try? Data(blockingContentsOf: index) else { return nil }
        let ids = Self.screenSaverStrings(in: data)
        guard !ids.isEmpty else { return nil }
        let videos = videos(fileManager: fileManager)
        for id in ids {
            if let match = videos.first(where: { choice in
                guard case .system(let path) = choice else { return false }
                return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent == id
            }) {
                return match
            }
        }
        return nil
    }

    /// Every string in the index's idle choice, in order: the asset id is one of them. The idle
    /// choice is `Idle` of `AllSpacesAndDisplays`, else its `Linked` one (the screen saver follows
    /// the wallpaper), else the same in the first display that has one. A choice's
    /// `Configuration` is itself a property list, read too.
    nonisolated static func screenSaverStrings(in data: Data) -> [String] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var scopes: [[String: Any]] = []
        if let all = root["AllSpacesAndDisplays"] as? [String: Any] { scopes.append(all) }
        if let displays = root["Displays"] as? [String: Any] {
            scopes += displays.keys.sorted().compactMap { displays[$0] as? [String: Any] }
        }
        for scope in scopes {
            guard let idle = (scope["Idle"] ?? scope["Linked"]) as? [String: Any] else { continue }
            var found: [String] = []
            collectStrings(idle, into: &found, depth: 0)
            let ids = found.filter(isSafeAerialID)
            if !ids.isEmpty { return ids }
        }
        return []
    }

    /// The strings in a property list value, nested data decoded as one; at most 8 levels deep.
    private nonisolated static func collectStrings(_ value: Any, into found: inout [String], depth: Int) {
        guard depth < 8 else { return }
        switch value {
        case let text as String:
            found.append(text)
        case let data as Data:
            if let nested = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                collectStrings(nested, into: &found, depth: depth + 1)
            }
        case let list as [Any]:
            for item in list { collectStrings(item, into: &found, depth: depth + 1) }
        case let dictionary as [String: Any]:
            for (_, item) in dictionary.sorted(by: { $0.key < $1.key }) { collectStrings(item, into: &found, depth: depth + 1) }
        default:
            break
        }
    }
}
