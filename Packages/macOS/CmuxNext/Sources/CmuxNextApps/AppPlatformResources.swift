public import Foundation

/// Files synced from `cmux-tui/crates/cmux-app-host` and `samples/apps` by
/// `scripts/cmux-next/sync-app-runtime.sh` (never edit the copies): the
/// scope table the permission policy reads, and the sample manifests and
/// assets the demo transport and the store icons use. The app supervisor in
/// the daemon runs apps; the client bundles no runtime.
public nonisolated enum AppPlatformResources {
    /// `Resources/AppPlatform` inside the module bundle.
    public static var root: URL {
        Bundle.module.resourceURL?.appending(path: "AppPlatform", directoryHint: .isDirectory)
            ?? Bundle.module.bundleURL.appending(path: "AppPlatform", directoryHint: .isDirectory)
    }

    /// `generated/scopes.json`: op name -> scope and class.
    public static var scopesFile: URL { root.appending(path: "scopes.json") }
    /// The sample apps' manifests and assets, one directory per app.
    public static var samples: URL { root.appending(path: "samples", directoryHint: .isDirectory) }
    /// First-party apps shipped inside cmux (`first-party-apps/<name>` with a BUNDLED marker).
    public static var firstParty: URL { root.appending(path: "first-party", directoryHint: .isDirectory) }

    /// The bundled sample manifests (sorted by directory name). Reads the
    /// disk: call it off the main actor (`preload`), or in tests and the
    /// fake supervisor.
    public static func sampleManifests() -> [(manifest: AppManifest, directory: URL)] { manifests(in: samples) }

    /// The bundled first-party manifests (same rules as `sampleManifests`).
    public static func firstPartyManifests() -> [(manifest: AppManifest, directory: URL)] { manifests(in: firstParty) }

    static func manifests(in folder: URL) -> [(manifest: AppManifest, directory: URL)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { directory in
            (try? Data(contentsOf: directory.appending(path: "cmux-app.json"))).flatMap(AppManifest.decode).map { ($0, directory) }
        }
    }
}

/// Reads the app platform resources from disk. The client calls it only
/// from `AppPlatformResources.preload`, which runs off the main actor;
/// tests inject a recorder to prove that.
public nonisolated protocol AppResourceLoading: Sendable {
    /// App id -> the bundled sample's directory.
    func sampleDirectories() -> [String: URL]
    /// Loads `AppScopeTable.bundled` so no later reader pays for the file read.
    func warmScopeTable()
}

/// The module's bundled resources.
public nonisolated struct BundledAppResources: AppResourceLoading {
    public init() {}

    public func sampleDirectories() -> [String: URL] {
        Dictionary((AppPlatformResources.firstPartyManifests() + AppPlatformResources.sampleManifests()).map { ($0.manifest.id, $0.directory) },
                   uniquingKeysWith: { first, _ in first })
    }

    public func warmScopeTable() { _ = AppScopeTable.bundled }
}

extension AppPlatformResources {
    /// Loads the sample directories and the scope table once, off the main
    /// actor (app start). Until it finishes, icons of bundled samples fall
    /// back to a symbol; nothing on the main actor waits for it.
    @concurrent
    public static func preload(using loader: some AppResourceLoading = BundledAppResources()) async {
        loader.warmScopeTable()
        AppBundleLocator.store(loader.sampleDirectories())
    }
}
