import Atomics
public import CmuxNextWakeups

/// Where the process's browser source registry lives once read: the composition root loads it on the files
/// lane at launch (``load(on:)``), so the import pickers, the detector and the Passwords page find it in
/// memory. Chrome installs its process-wide tables the same way, once, before readers come
/// (`base::FeatureList::SetInstance`, base/feature_list.h); cmux's ``FeatureList/Slot`` is the same pattern.
///
/// A read before the load (a test, or a reader that beat the lane) reads the file itself through the checked
/// seam, so on the main thread the blocking detector records it; the first value stored wins. It replaces a
/// static initializer that read the file on whichever thread asked first while the others waited
/// (p02-threads-122).
public nonisolated final class BrowserSourceRegistryInstall: Sendable {
    /// The process's install: the registry is the bundle's checked-in data, the same for every reader.
    public static let shared = BrowserSourceRegistryInstall()

    private final class Installed: Sendable {
        let registry: BrowserSourceRegistry
        init(_ registry: BrowserSourceRegistry) { self.registry = registry }
    }

    private let installed = ManagedAtomicLazyReference<Installed>()
    private let read: @Sendable () -> BrowserSourceRegistry

    /// - Parameter read: Reads the registry (``BrowserSourceRegistry/loadBundled()``; tests count reads).
    init(read: @escaping @Sendable () -> BrowserSourceRegistry = { BrowserSourceRegistry.loadBundled() }) {
        self.read = read
    }

    /// Whether the registry is in memory.
    public var isLoaded: Bool { installed.load() != nil }

    /// The registry: in memory after ``load(on:)``; before it, read here.
    public var registry: BrowserSourceRegistry {
        if let installed = installed.load() { return installed.registry }
        return installed.storeIfNilThenLoad(Installed(read())).registry
    }

    /// Reads the registry on `work`'s files lane (launch), so later reads find it in memory.
    public func load(on work: BackgroundWork) {
        work.post(.userVisible, mayBlock: .files) { [self] in _ = registry }
    }
}
