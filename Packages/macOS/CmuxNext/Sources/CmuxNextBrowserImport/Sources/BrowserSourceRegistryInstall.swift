import CmuxNextCompat
public import CmuxNextWakeups

/// Where the process's browser source registry lives once read: the composition root loads it on the files
/// lane at launch (``load(on:)``), so the import pickers, the detector and the Passwords page find it in
/// memory (a `PreloadedValue`). A read before the load (a test, or a reader that beat the lane) reads the
/// file itself through the checked seam, so on the main thread the blocking detector records it. It replaces
/// a static initializer that read the file on whichever thread asked first while the others waited.
public nonisolated final class BrowserSourceRegistryInstall: Sendable {
    /// The process's install: the registry is the bundle's checked-in data, the same for every reader.
    public static let shared = BrowserSourceRegistryInstall()

    private let slot: PreloadedValue<BrowserSourceRegistry>

    /// - Parameter read: Reads the registry (``BrowserSourceRegistry/loadBundled()``; tests count reads).
    init(read: @escaping @Sendable () -> BrowserSourceRegistry = { BrowserSourceRegistry.loadBundled() }) {
        slot = PreloadedValue(read: read)
    }

    /// Whether the registry is in memory.
    public var isLoaded: Bool { slot.isLoaded }

    /// The registry: in memory after ``load(on:)``; before it, read here.
    public var registry: BrowserSourceRegistry { slot.value }

    /// Reads the registry on `work`'s files lane (launch), so later reads find it in memory.
    public func load(on work: BackgroundWork) {
        work.post(.userVisible, mayBlock: .files) { [slot] in slot.load() }
    }
}
