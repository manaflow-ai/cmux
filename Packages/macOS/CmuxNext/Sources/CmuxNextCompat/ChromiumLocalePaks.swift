public import Foundation

/// The embedded Chromium's locale paks that arrive on first use (CMUX-570, cmux#45928's language
/// packs). A NIGHTLY keeps only Chromium's English pak in the signed framework; a language's pack
/// carries that language's `ChromiumLocales/<catalog>.lproj/locale.pak`. The daemon unpacks the
/// pack into its cache, and ``install(pak:bundleID:)`` copies the pak to one stable folder outside
/// the signed app, which Chromium reads first (`CefSettings.locales_dir_path`, cmux_shim_set_locales_dir)
/// the next time it starts. The copy is the only place Chromium looks, so the daemon's cache folders
/// (named by hash) can change without the browser losing its language.
public struct ChromiumLocalePaks {
    public init() {}
    /// The folder of `<catalog>.lproj/locale.pak` files for the app `bundleID`, in Application Support
    /// (beside, not inside, the daemon's `LanguagePacks` cache, which it may prune).
    public static func directory(bundleID: String) -> URL {
        NextSupport.applicationSupportDirectory()
            .appending(path: bundleID, directoryHint: .isDirectory)
            .appending(path: "ChromiumLocales", directoryHint: .isDirectory)
    }

    /// Copies the pack's `<catalog>.lproj/locale.pak` to `<directory>/<catalog>.lproj/locale.pak`,
    /// replacing an older copy in one step so Chromium never reads half a pak. Returns the catalog
    /// folder's name (`de.lproj`), or nil when `pak` is not a `locale.pak` inside an `.lproj` folder
    /// or the copy failed.
    @discardableResult
    public static func install(pak: URL, into directory: URL, fileManager: FileManager = .default) -> String? {
        let lproj = pak.deletingLastPathComponent()
        guard pak.lastPathComponent == "locale.pak", lproj.pathExtension == "lproj",
              fileManager.fileExists(atPath: pak.path)
        else { return nil }
        let folder = directory.appending(path: lproj.lastPathComponent, directoryHint: .isDirectory)
        let target = folder.appending(path: "locale.pak", directoryHint: .notDirectory)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let staged = folder.appending(path: ".locale.pak.\(UUID().uuidString)", directoryHint: .notDirectory)
            try fileManager.copyItem(at: pak, to: staged)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: target)
            }
            return lproj.lastPathComponent
        } catch {
            return nil
        }
    }
}
