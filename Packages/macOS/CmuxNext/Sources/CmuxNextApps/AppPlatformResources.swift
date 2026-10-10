public import Foundation

/// Files synced from `cmux-tui/crates/cmux-app-host`, `first-party-apps` and
/// `samples/apps` by `scripts/cmux-next/sync-app-runtime.sh` (never edit the
/// copies): the scope tables the permission prototype reads, the
/// first-party app packages the local daemon serves (the App points the
/// daemon at ``firstParty``), and the sample manifests and assets the demo
/// transport and the store icons use. The app supervisor in the daemon runs
/// apps; the client bundles no runtime and no validator.
public nonisolated enum AppPlatformResources {
    /// `Resources/AppPlatform` inside the module bundle.
    public static var root: URL {
        Bundle.module.resourceURL?.appending(path: "AppPlatform", directoryHint: .isDirectory)
            ?? Bundle.module.bundleURL.appending(path: "AppPlatform", directoryHint: .isDirectory)
    }

    /// `generated/scopes.json`: op name -> scope and class.
    public static var scopesFile: URL { root.appending(path: "scopes.json") }
    /// `schema/v2/scope-classes.json`: the risk class of every scope, shared
    /// with the Rust validator (`cmux-app-manifest`).
    public static var scopeClassesFile: URL { root.appending(path: "scope-classes.json") }
    /// The sample apps' manifests and assets, one directory per app.
    public static var samples: URL { root.appending(path: "samples", directoryHint: .isDirectory) }
    /// First-party apps shipped inside cmux (`first-party-apps/<name>` with a
    /// BUNDLED marker): whole packages, which the local daemon's supervisor
    /// reads as its first-party directory (`CMUX_APPS_FIRST_PARTY_DIR`).
    public static var firstParty: URL { root.appending(path: "first-party", directoryHint: .isDirectory) }

    /// The bundled sample manifests (sorted by directory name). Reads the
    /// disk: call it off the main actor (`preload`), or in tests and the
    /// fake supervisor.
    public static func sampleManifests() -> [(manifest: AppManifest, directory: URL)] { manifests(in: samples) }

    /// The bundled first-party manifests (v2 first, as the supervisor reads them).
    public static func firstPartyManifests() -> [(manifest: AppManifest, directory: URL)] { manifests(in: firstParty) }

    static func manifests(in folder: URL) -> [(manifest: AppManifest, directory: URL)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { directory in
            let manifest = ["cmux-app.v2.json", "cmux-app.json"].lazy
                .compactMap { (try? Data(contentsOf: directory.appending(path: $0))).flatMap(AppManifest.decode) }.first
            return manifest.map { ($0, directory) }
        }
    }
}

/// Reads the app platform resources from disk. The client calls it only
/// from `AppPlatformResources.preload`, which runs off the main actor;
/// tests inject a recorder to prove that.
public nonisolated protocol AppResourceLoading: Sendable {
    /// App id -> the bundled package's directory.
    func sampleDirectories() -> [String: URL]
}

/// The module's bundled resources.
public nonisolated struct BundledAppResources: AppResourceLoading {
    public init() {}

    public func sampleDirectories() -> [String: URL] {
        Dictionary((AppPlatformResources.firstPartyManifests() + AppPlatformResources.sampleManifests()).map { ($0.manifest.id, $0.directory) },
                   uniquingKeysWith: { first, _ in first })
    }
}

extension AppPlatformResources {
    /// Loads the bundled package directories once, off the main actor (app
    /// start). Until it finishes, icons of apps the
    /// supervisor sent no `bundle_dir` for fall back to a symbol; nothing on
    /// the main actor waits for it.
    @concurrent
    public static func preload(using loader: some AppResourceLoading = BundledAppResources()) async {
        AppBundleLocator.store(loader.sampleDirectories())
    }
}
