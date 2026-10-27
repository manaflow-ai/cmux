import QuartzCore

/// The ``LoopHost`` of a host that has no window visibility to follow: tests, the standalone
/// MessagesLab harness, and the iOS transcript (UIKit stops a background app's render server
/// updates itself). Each loop goes on its layer as it is attached and stays until detached. The
/// Mac app never uses it: its views hand their Shared children a `LoopVisibility`.
@MainActor public final class StandaloneLoopHost: LoopHost {
    private struct Entry {
        weak var layer: CALayer?
        let key: String
    }

    private var entries: [Entry] = []

    /// Nonisolated, so a layer or view property can default to one.
    nonisolated public init() {}

    public func attach(_ layer: CALayer, key: String, make: @escaping @MainActor () -> CAAnimation?) {
        entries.removeAll { $0.layer == nil || ($0.layer === layer && $0.key == key) }
        entries.append(Entry(layer: layer, key: key))
        layer.removeAnimation(forKey: key)
        if let loop = make() { layer.add(loop, forKey: key) }
    }

    public func detach(_ layer: CALayer, key: String) {
        entries.removeAll { $0.layer == nil || ($0.layer === layer && $0.key == key) }
        layer.removeAnimation(forKey: key)
    }

    public func detachAll() {
        for entry in entries { entry.layer?.removeAnimation(forKey: entry.key) }
        entries.removeAll()
    }

    /// The attached loops whose layer is alive.
    public var attachedCount: Int { entries.filter { $0.layer != nil }.count }
}
