import AppKit
import CmuxNextCompat

/// The LaunchServices answers of the link and path menus (``LinkMenu``), kept per key so a
/// right-click does not ask LaunchServices again on the main thread. Each right-click on a link
/// asked for every app that opens it, the default one, and an icon per app (up to 24), all
/// synchronously while the menu built: 100 ms to seconds while LaunchServices is cold, and once
/// more for every click of a burst. Now the first menu for a key asks (as before) and later
/// menus show the kept answer at once, while one background refresh per key brings it up to
/// date for the next menu (an app installed since appears one menu later).
///
/// Owned by the ``LinkRouter`` every menu is built with (``LinkRouter/menuApps``): the app's one
/// router keeps one cache for every menu of every surface, and a test's router keeps its own.
final class LinkMenuAppCache {
    nonisolated private struct Entry: Sendable {
        var apps: [URL]
        var refreshing = false
    }

    nonisolated private enum Lookup: Sendable {
        case kept([URL], refresh: Bool)
        case missing
    }

    /// Read on main and written by the background refresh, hence a lock and not main isolation.
    nonisolated private let entries = Mutex<[String: Entry]>([:])
    /// App icons by path, 16 pt. An app's icon is read once per cache.
    private var icons: [String: NSImage] = [:]

    init() {}

    /// The apps for `key`: the kept answer (and a refresh in the background), else `compute()` now.
    func apps(for key: String, compute: @escaping @Sendable () -> [URL]) -> [URL] {
        let lookup = entries.withLock { entries -> Lookup in
            guard var entry = entries[key] else { return .missing }
            let refresh = !entry.refreshing
            entry.refreshing = true
            entries[key] = entry
            return .kept(entry.apps, refresh: refresh)
        }
        switch lookup {
        case .missing:
            let apps = compute()
            entries.withLock { $0[key] = Entry(apps: apps) }
            return apps
        case let .kept(apps, refresh):
            if refresh {
                // task-owner: one LaunchServices refresh per key at a time; it only updates this cache
                Task.detached(priority: .utility) { [self] in
                    let fresh = compute()
                    entries.withLock { $0[key] = Entry(apps: fresh) }
                }
            }
            return apps
        }
    }

    /// The 16 pt icon of `app`, read once per cache.
    func icon(for app: URL) -> NSImage {
        if let icon = icons[app.path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        icons[app.path] = icon
        return icon
    }
}
