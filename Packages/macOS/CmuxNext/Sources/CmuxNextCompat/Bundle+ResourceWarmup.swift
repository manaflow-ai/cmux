public import Foundation

extension Bundle {
    /// The resource bundles ``warmResourceBundlesInBackground(in:)`` opened, held for the process.
    private static let warmedResourceBundles = Mutex<[Bundle]>([])

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
                  let names = try? FileManager.default.contentsOfDirectory(atPath: resources.path) else { return }
            let opened = names.filter { $0.hasSuffix(".bundle") }.sorted().compactMap { name -> Bundle? in
                guard let bundle = Bundle(url: resources.appending(path: name, directoryHint: .isDirectory)) else { return nil }
                // Loads the Localizable table of the preferred language (a file read per bundle).
                _ = bundle.localizedString(forKey: "cmux.warmup", value: nil, table: nil)
                return bundle
            }
            warmedResourceBundles.withLock { $0 = opened }
        }
        thread.name = "cmux-next resource bundle warm-up"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
