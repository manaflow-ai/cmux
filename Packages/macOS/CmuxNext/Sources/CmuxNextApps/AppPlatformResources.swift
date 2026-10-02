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

    /// The bundled sample manifests (sorted by directory name).
    public static func sampleManifests() -> [(manifest: AppManifest, directory: URL)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { directory in
            (try? Data(contentsOf: directory.appending(path: "cmux-app.json"))).flatMap(AppManifest.decode).map { ($0, directory) }
        }
    }
}

/// Where an app's bundle files (icons, scene images) are on this Mac:
/// the bundled sample's directory when cmux ships one, else nil (the icon
/// falls back to a symbol). The supervisor's bundle cache is not shared
/// with the client.
public nonisolated enum AppBundleLocator {
    private static let directories: [String: URL] = Dictionary(
        AppPlatformResources.sampleManifests().map { ($0.manifest.id, $0.directory) }, uniquingKeysWith: { first, _ in first })

    public static func directory(for app: String) -> URL? { directories[app] }
}
