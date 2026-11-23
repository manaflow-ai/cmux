import CmuxNextCompat
import Foundation

/// The Resources files cmux-tui owns (the shipped theme files and sidebar looks), as the daemon writes them
/// at `<daemon state directory>/shipped/<folder>/` (cmux-config `shipped.rs`, `shipped-resources.json`). The
/// daemon embeds these files, so a change to one ships with the daemon binary: hot-apply swaps it into a
/// running app with no new build. A `stamp` there changes when any file does.
public nonisolated struct ShippedResourceFolder: Sendable, Equatable {
    public static let folderName = "shipped"
    /// `<daemon state directory>/shipped`.
    public let root: URL

    /// The build's `CMUX_TUI_STATE_DIR`, or cmux-tui's default sessions directory when it sets none.
    public init(daemonStateDirectory stateDirectory: URL?) {
        let sessions = stateDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/cmux-tui/sessions", directoryHint: .isDirectory)
        root = sessions.appending(path: Self.folderName, directoryHint: .isDirectory)
    }

    /// Folder `name` (`theme-files`, `sidebar-looks`) when the daemon has written it, else nil. File I/O.
    public func folder(named name: String) -> URL? {
        let folder = root.appending(path: name, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        return FileManager.checked.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? folder : nil
    }

    /// The daemon's digest of every file it wrote; nil before it wrote any. File I/O.
    public func stamp() -> String? {
        try? String(blockingContentsOf: root.appending(path: "stamp"), encoding: .utf8)
    }
}

extension SettingsBuildDefaults {
    /// These defaults, reading the shipped theme files and sidebar looks from the daemon's copy
    /// (``ShippedResourceFolder``) when it has written one.
    public func shipping(daemonStateDirectory: URL?) -> SettingsBuildDefaults {
        var defaults = self
        defaults.shipped = ShippedResourceFolder(daemonStateDirectory: daemonStateDirectory)
        return defaults
    }

    /// Folder `name` of the shipped files: the daemon's copy, else the app bundle's. File I/O.
    func shippedFolder(named name: String) -> URL? {
        shipped?.folder(named: name) ?? Bundle.main.resourceURL?.appending(path: name, directoryHint: .isDirectory)
    }
}

extension SettingsController {
    /// Each time `isLive` turns true (a daemon start, hot-apply's swap), reloads settings when the daemon's
    /// shipped files changed, so the theme files and looks of the daemon now running apply.
    func followShippedResources(isLive: @escaping @MainActor @Sendable () -> Bool) {
        guard let shipped = buildDefaults.shipped else { return }
        Task { [weak self] in
            var seen = shipped.stamp()
            for await live in ObservationStream({ isLive() }) where live {
                let stamp = shipped.stamp()
                if stamp != seen { seen = stamp; await self?.reload() }
            }
        }
    }
}
