public import Foundation

/// The resource bundles this process opened and holds: the launch warm-up's, and the downloaded
/// language pack's (CMUX-570).
struct OpenedResourceBundles {
    /// Every SwiftPM resource bundle of the app, opened by the warm-up.
    var warmed: [Bundle] = []
    /// The active language pack's bundles, by the folder name of the module bundle each one stands
    /// in for (`CmuxNext_CmuxNextSettings.bundle`). Empty until a pack is active.
    var languagePack: [String: Bundle] = [:]
}

extension Bundle {
    /// The resource bundles the process opened (``warmResourceBundlesInBackground(in:)``,
    /// ``activateLanguagePack(root:)``), held for the process.
    private static let warmedResourceBundles = Mutex(OpenedResourceBundles())

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
            warmedResourceBundles.withLock { $0.warmed = opened }
        }
        thread.name = "cmux-next resource bundle warm-up"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// The bundle to read this module bundle's strings from: the active language pack's copy of it
    /// when there is one, else this bundle.
    ///
    /// A NIGHTLY ships only English in its SwiftPM resource bundles (CMUX-570: the other 20
    /// languages were 21.9 MB installed). The home daemon downloads the person's language on first
    /// use (`language_packs.ensure`, pinned by sha256 in `Contents/Resources/language-packs.json`)
    /// and unpacks it as one folder holding, for each module bundle, a bundle of the same name with
    /// only that language's `.lproj`. Until it is there, and offline, strings read English. Each
    /// module reads its strings through its own `Bundle.l10n` (`Bundle.module.strings`).
    public var strings: Bundle {
        Self.warmedResourceBundles.withLock { $0.languagePack[bundleURL.lastPathComponent] } ?? self
    }

    /// Makes the language pack unpacked at `root` the source of every module bundle's strings.
    /// Opens each of its bundles and loads one table first, on the caller's thread (call it off the
    /// main thread), so a later string read on the main thread finds them open. Strings already
    /// drawn stay as they are; text made after this reads the pack.
    public static func activateLanguagePack(root: URL) {
        guard let names = try? FileManager.checked.contentsOfDirectory(atPath: root.path) else { return }
        var bundles: [String: Bundle] = [:]
        for name in names where name.hasSuffix(".bundle") {
            guard let pack = Bundle(url: root.appending(path: name, directoryHint: .isDirectory)) else { continue }
            _ = pack.localizedString(forKey: "cmux.warmup", value: nil, table: nil)
            bundles[name] = pack
        }
        warmedResourceBundles.withLock { $0.languagePack = bundles }
    }
}
