public import CmuxNextCompat
public import Foundation

/// The UUIDs of cmux's own images (the executable, its frameworks and helpers), from this launch
/// and the builds before it, so a MetricKit frame from before an update is still ours by UUID and
/// never by a name that only looks like ours (``ImageClassifier``).
///
/// The first read takes the images loaded from inside the app bundle now, adds the ones stored
/// by earlier launches and stores the union (newest first, at most ``limit``). Later reads use
/// the cached set. Read off the main thread (it walks dyld's image list once).
///
/// ```swift
/// let own = OwnImageUUIDs(appBundlePath: Bundle.main.bundlePath, images: { DyldImageResolver().loadedImages() })
/// let classifier = ImageClassifier(appBundlePath: Bundle.main.bundlePath, forbiddenTerms: [], ownUUIDs: { own.uuids() })
/// ```
public final class OwnImageUUIDs: Sendable {
    /// The defaults key of the stored UUIDs.
    public static let key = "cmux.next.hangReports.ownImageUUIDs"
    /// The most UUIDs kept (a build has a few dozen images).
    public static let limit = 400

    private let appBundlePath: String
    private let suiteName: String?
    private let images: @Sendable () -> [LoadedImage]
    // Lock carve-out: a cache read from the collector's utility task and the service actor; an actor
    // would make the classifier's synchronous frame mapping async.
    private let cache = Mutex<Set<String>?>(nil)

    /// - Parameters:
    ///   - appBundlePath: The running app's bundle; images loaded from inside it are ours.
    ///   - suiteName: The defaults domain (nil: the app's own; tests pass their own).
    ///   - images: The images loaded now (``DyldImageResolver/loadedImages()``; tests pass a list).
    public init(appBundlePath: String, suiteName: String? = nil, images: @escaping @Sendable () -> [LoadedImage]) {
        self.appBundlePath = appBundlePath.hasSuffix("/") ? appBundlePath : appBundlePath + "/"
        self.suiteName = suiteName
        self.images = images
    }

    /// Our images' UUIDs, uppercase.
    public func uuids() -> Set<String> {
        if let cached = cache.withLock({ $0 }) { return cached }
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let now = images().filter { $0.path.hasPrefix(appBundlePath) }.map(\.uuid)
        let stored = defaults.stringArray(forKey: Self.key) ?? []
        var seen = Set<String>()
        let merged = (now + stored).filter { ImageClassifier.isUUID($0) && seen.insert($0.uppercased()).inserted }
            .map { $0.uppercased() }.prefix(Self.limit)
        defaults.set(Array(merged), forKey: Self.key)
        let result = Set(merged)
        cache.withLock { $0 = result }
        return result
    }
}
