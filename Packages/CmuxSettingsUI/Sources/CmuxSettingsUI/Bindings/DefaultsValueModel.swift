import CmuxSettings
import Foundation
import Observation

/// `@Observable` view-model that projects one ``DefaultsKey`` value into
/// SwiftUI-bindable state.
///
/// SwiftUI views need synchronous reads against a `Binding<Value>` in
/// their body. The ``UserDefaultsSettingsStore`` API is `async`, so we
/// can't bind directly. ``DefaultsValueModel`` is the bridge:
///
/// 1. On construction it seeds ``current`` from a synchronous store read
///    and subscribes to ``UserDefaultsSettingsStore/values(for:)`` for
///    later changes. That stream is `.bufferingNewest(1)`, so a burst of
///    writes (e.g. a `ColorPicker` drag) coalesces to the latest value
///    instead of replaying every intermediate back through ``current``.
/// 2. SwiftUI views read ``current`` synchronously and write via ``set(_:)``.
/// 3. ``set(_:)`` updates ``current`` optimistically (immediate UI) and
///    persists the write in a fire-and-forget `Task`.
///
/// Lifecycle: the observation `Task` captures `self` weakly and exits
/// when the model is deallocated, so no explicit cancellation is needed.
@MainActor
@Observable
public final class DefaultsValueModel<Value: SettingCodable> {
    /// The most recently observed value. SwiftUI views read this synchronously.
    public private(set) var current: Value

    private let store: UserDefaultsSettingsStore
    private let key: DefaultsKey<Value>

    /// Creates a model bound to ``key`` in ``store``.
    ///
    /// - Parameters:
    ///   - store: The UserDefaults store to read from and write to.
    ///   - key: The setting to observe.
    public convenience init(store: UserDefaultsSettingsStore, key: DefaultsKey<Value>) {
        self.init(store: store, key: key, makeStream: { store.values(for: key) })
    }

    /// Designated initializer with an injectable change-stream factory.
    ///
    /// The `makeStream` seam lets tests drive the observation with a stream
    /// whose teardown they can observe, proving the model cancels its
    /// observation on deallocation. Production code uses the public
    /// `init(store:key:)`, which wires `makeStream` to the store.
    ///
    /// - Parameters:
    ///   - store: The UserDefaults store used for writes (`set`/`reset`).
    ///   - key: The setting to observe.
    ///   - makeStream: Builds the change stream this model iterates.
    init(
        store: UserDefaultsSettingsStore,
        key: DefaultsKey<Value>,
        makeStream: @escaping () -> AsyncStream<Value>
    ) {
        self.store = store
        self.key = key
        // Seed with the key default; the observation stream's first
        // element (the actual stored value) lands immediately after and
        // is the sole writer of `current` thereafter.
        self.current = key.defaultValue
        Task { [weak self] in
            for await value in makeStream() {
                guard let self else { return }
                if Task.isCancelled { break }
                self.current = value
            }
        }
    }

    /// Persists the value. The observation stream is the single writer of
    /// ``current``, so the UI reflects the change once the write lands and
    /// the stream yields it back (a small storage round-trip). Synchronous
    /// because SwiftUI `Binding` setters can't `await`; the write itself
    /// runs in a fire-and-forget `Task`.
    public func set(_ value: Value) {
        Task { [store, key] in
            await store.set(value, for: key)
        }
    }

    /// Removes the override; ``current`` updates when the stream observes
    /// the reset.
    public func reset() {
        Task { [store, key] in
            await store.reset(key)
        }
    }
}
