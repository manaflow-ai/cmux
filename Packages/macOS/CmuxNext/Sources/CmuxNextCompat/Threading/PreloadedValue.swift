import Atomics

/// A value read once, on a lane before its readers come, then held in memory: a file the bundle ships, the
/// running code's signature. The owner reads it on a `BackgroundWork` lane at launch
/// (`work.post(.userVisible, mayBlock: .files) { value.load() }`), so a main-thread reader finds it in memory.
/// Chrome installs its process-wide tables the same way, once, before readers come
/// (`base::FeatureList::SetInstance`, base/feature_list.h).
///
/// A read before the load (a test, or a reader that beat the lane) runs `read` itself, through the checked
/// seams it uses, so on the main thread the blocking detector records it; the first value stored wins. It
/// replaces a static initializer that blocked whichever thread asked first while the others waited.
public nonisolated final class PreloadedValue<Value: Sendable>: Sendable {
    private final class Installed: Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private let installed = ManagedAtomicLazyReference<Installed>()
    private let read: @Sendable () -> Value

    /// - Parameter read: Reads the value (blocking: a file, a system call); runs once unless readers race the load.
    public init(read: @escaping @Sendable () -> Value) {
        self.read = read
    }

    /// Whether the value is in memory.
    public var isLoaded: Bool { installed.load() != nil }

    /// The value: in memory after ``load()``; before it, read here.
    public var value: Value {
        if let installed = installed.load() { return installed.value }
        return installed.storeIfNilThenLoad(Installed(read())).value
    }

    /// Reads the value so later reads find it in memory. It blocks: call it on a lane, never on the main thread.
    public func load() { _ = value }
}
