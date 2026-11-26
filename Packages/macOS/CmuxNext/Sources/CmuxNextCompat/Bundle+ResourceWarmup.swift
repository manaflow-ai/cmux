#if canImport(Darwin)
public import Foundation

/// The resource bundles this process opened and holds: the launch warm-up's, and the downloaded
/// language pack's (CMUX-570).
struct OpenedResourceBundles {
    /// Every SwiftPM resource bundle of the app, opened by the warm-up (nil until it ends).
    var warmed: [Bundle]?
    /// What ``Foundation/Bundle/forEachWarmedResourceBundle(_:)`` asked for before the warm-up ended.
    var waiting: [@Sendable (Bundle) -> Void] = []
    /// The active language pack's bundles, by the folder name of the module bundle each one stands
    /// in for (`CmuxNext_CmuxNextSettings.bundle`). Empty until a pack is active.
    var languagePack: [String: Bundle] = [:]
    /// The active pack's web page string tables (`<bundle>/Contents/Resources/.../locales/<lang>.js`),
    /// by that path, to the file in the pack. Empty until a pack is active.
    var languagePackWebFiles: [String: URL] = [:]
    /// Told each time a pack becomes active (``AppLanguage`` redraws the text that read the old one).
    var packObservers: [@Sendable () -> Void] = []
}

extension Bundle {
    /// The resource bundles the process opened (``warmResourceBundlesInBackground(in:)``,
    /// ``activateLanguagePack(root:)``), held for the process.
    private static let openedResourceBundles = Mutex(OpenedResourceBundles())

    /// Runs `body` on each resource bundle the launch warm-up opened: now, on the caller's thread,
    /// when it has ended, else on its thread when it ends. No disk access (`AppLanguage` adopts
    /// them so their strings follow `app.language`).
    public static func forEachWarmedResourceBundle(_ body: @escaping @Sendable (Bundle) -> Void) {
        let ready = openedResourceBundles.withLock { opened -> [Bundle]? in
            if let bundles = opened.warmed { return bundles }
            opened.waiting.append(body)
            return nil
        }
        ready?.forEach(body)
    }

    /// Opens every SwiftPM resource bundle of the app (`Contents/Resources/*.bundle`, 55 of them)
    /// and loads its string table, on a new background thread. A module's first `Bundle.module`
    /// read (any `String(localized:bundle: .module)`) otherwise creates the bundle on the main
    /// thread, and `CFBundleCreate` lists the bundle's folder to find its version: on a cold file
    /// cache (after an update) that held the main thread 2 s+ (Sentry MainThreadStall in
    /// `_CFBundleGetBundleVersionForURL` from `DaemonRecoveryStrings.retryNow` while the
    /// connecting screen built). NSBundle keeps one instance per path, so the later
    /// `Bundle.module` read gets this one. Call once, early in launch.
    public static func warmResourceBundlesInBackground(in resources: URL? = Bundle.main.resourceURL) {
        let thread = Thread {
            guard let resources,
                  let names = try? FileManager.checked.contentsOfDirectory(atPath: resources.path) else { return }
            let opened = names.filter { $0.hasSuffix(".bundle") }.sorted().compactMap { name -> Bundle? in
                guard let bundle = Bundle(url: resources.appending(path: name, directoryHint: .isDirectory)) else { return nil }
                // Loads the Localizable table of the preferred language (a file read per bundle).
                _ = bundle.localizedString(forKey: "cmux.warmup", value: nil, table: nil)
                return bundle
            }
            let waiting = openedResourceBundles.withLock { state in
                state.warmed = opened
                defer { state.waiting = [] }
                return state.waiting
            }
            for body in waiting { opened.forEach(body) }
        }
        thread.name = "cmux-next resource bundle warm-up"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// The bundle to read this module bundle's strings from: the active language pack's copy of it
    /// when there is one, else this bundle. ``inAppLanguage`` reads through it.
    ///
    /// A NIGHTLY ships only English in its SwiftPM resource bundles (CMUX-570: the other 20
    /// languages were 21.9 MB installed). The home daemon downloads the person's language on first
    /// use (`language_packs.ensure`, pinned by sha256 in `Contents/Resources/language-packs.json`)
    /// and unpacks it as one folder holding, for each module bundle, a bundle of the same name with
    /// only that language's `.lproj`. Until it is there, and offline, strings read English.
    public var languagePackCopy: Bundle? {
        Self.openedResourceBundles.withLock { $0.languagePack[bundleURL.lastPathComponent] }
    }

    /// Calls `body` (on the activating thread) each time a language pack becomes active.
    public static func observeLanguagePacks(_ body: @escaping @Sendable () -> Void) {
        openedResourceBundles.withLock { $0.packObservers.append(body) }
    }

    /// Makes the language pack unpacked at `root` the source of every module bundle's strings.
    /// Opens each of its bundles and loads one table first, on the caller's thread (call it off the
    /// main thread), so a later string read on the main thread finds them open. Text that read a
    /// cmux string in an observation scope runs again (``observeLanguagePacks(_:)``).
    public static func activateLanguagePack(root: URL) {
        guard let names = try? FileManager.checked.contentsOfDirectory(atPath: root.path) else { return }
        var bundles: [String: Bundle] = [:]
        var webFiles: [String: URL] = [:]
        for name in names where name.hasSuffix(".bundle") {
            let url = root.appending(path: name, directoryHint: .isDirectory)
            guard let pack = Bundle(url: url) else { continue }
            _ = pack.localizedString(forKey: "cmux.warmup", value: nil, table: nil)
            bundles[name] = pack
            // The pages' and the agent pane's per-language string tables (one folder walk per bundle).
            let walk = FileManager.checked.enumerator(at: url, includingPropertiesForKeys: nil)
            while let file = walk?.nextObject() as? URL {
                guard file.pathExtension == "js", file.deletingLastPathComponent().lastPathComponent == "locales",
                      let path = webLocalePath(file) else { continue }
                webFiles[path] = file
            }
        }
        let observers = openedResourceBundles.withLock { state in
            state.languagePack = bundles
            state.languagePackWebFiles = webFiles
            return state.packObservers
        }
        for observer in observers { observer() }
    }

    /// Makes the module bundles the source of their own strings again (a language that needs no
    /// pack: English, or one the app pins none for), so an earlier choice's pack no longer answers.
    /// Text that read the pack runs again; with no pack active this does nothing.
    public static func deactivateLanguagePack() {
        let observers = openedResourceBundles.withLock { state -> [@Sendable () -> Void] in
            guard !state.languagePack.isEmpty || !state.languagePackWebFiles.isEmpty else { return [] }
            state.languagePack = [:]
            state.languagePackWebFiles = [:]
            return state.packObservers
        }
        for observer in observers { observer() }
    }

    /// The active language pack's copy of a web page string table the app does not ship
    /// (`CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages/settings/locales/de.js`), else nil.
    /// A page's loader asks for its language's file; the scheme handlers serve this one in its place.
    /// No disk access: the pack's files are listed once, when it is made active.
    public nonisolated static func languagePackFile(for file: URL) -> URL? {
        guard file.deletingLastPathComponent().lastPathComponent == "locales", let path = webLocalePath(file) else { return nil }
        return openedResourceBundles.withLock { $0.languagePackWebFiles[path] }
    }

    /// `file`'s path from its resource bundle's folder on (`CmuxNext_X.bundle/Contents/...`), or nil
    /// when it is in no `.bundle`.
    private nonisolated static func webLocalePath(_ file: URL) -> String? {
        let parts = file.standardizedFileURL.pathComponents
        guard let index = parts.lastIndex(where: { $0.hasSuffix(".bundle") }) else { return nil }
        return parts[index...].joined(separator: "/")
    }
}
#endif
