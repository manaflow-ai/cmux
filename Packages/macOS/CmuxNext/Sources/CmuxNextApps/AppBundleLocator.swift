public import Foundation
import Synchronization

/// Where an app's bundle files (icons, scene images) are on this Mac when
/// the supervisor sent no `bundle_dir`: the bundled sample's directory once
/// `AppPlatformResources.preload` filled the cache. Reads are memory only,
/// so the main actor never touches the disk here.
public nonisolated enum AppBundleLocator {
    private static let cache = Mutex<[String: URL]>([:])

    public static func directory(for app: String) -> URL? { cache.withLock { $0[app] } }

    static func store(_ directories: [String: URL]) {
        cache.withLock { $0.merge(directories) { current, _ in current } }
    }
}
