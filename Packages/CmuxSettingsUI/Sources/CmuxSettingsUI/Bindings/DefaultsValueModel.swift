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
/// 1. On construction, it subscribes to ``UserDefaultsSettingsStore/values(for:)``
///    in a fire-and-forget `Task` that copies new values into the
///    `@Observable` ``current`` property on the main actor.
/// 2. SwiftUI views read ``current`` synchronously.
/// 3. Setters write through to the store, which fires the next stream
///    element back into ``current``.
///
/// Lifecycle: the observation `Task` captures `self` weakly inside its
/// loop body and exits naturally when the model is deallocated, so no
/// explicit cancellation or `deinit` cleanup is required.
@MainActor
@Observable
public final class DefaultsValueModel<Value: SettingCodable> {
    /// The most recently observed value. Updated by the underlying store's
    /// `AsyncStream`. SwiftUI views read this synchronously.
    public private(set) var current: Value

    private let store: UserDefaultsSettingsStore
    private let key: DefaultsKey<Value>

    /// Creates a model bound to ``key`` in ``store``.
    ///
    /// - Parameters:
    ///   - store: The UserDefaults store to read from and write to.
    ///   - key: The setting to observe.
    public init(store: UserDefaultsSettingsStore, key: DefaultsKey<Value>) {
        self.store = store
        self.key = key
        // Seed from the actual stored value (synchronous, thread-safe
        // read) rather than the key default. Section views construct
        // these models inline in their body, so a fresh instance must
        // show the real current value immediately or the control reads
        // as unresponsive until the async stream catches up.
        self.current = store.currentValue(for: key)
        Task { [weak self, store, key] in
            for await value in store.values(for: key) {
                guard let self else { return }
                if Task.isCancelled { break }
                self.current = value
            }
        }
    }

    /// Writes ``value`` through to the underlying store.
    ///
    /// Synchronous so it can be called directly from a SwiftUI
    /// `Binding` setter (which cannot `await`); the actual write is
    /// dispatched to the actor-isolated store in a `Task`. ``current``
    /// is intentionally *not* mutated here — the observation stream set
    /// up in ``init`` is the single source of truth and updates
    /// ``current`` (on the main actor) once the write lands and
    /// `UserDefaults.didChangeNotification` fires. The store is an
    /// `actor`, so concurrent writes serialize with last-write-wins; no
    /// extra synchronization is needed.
    public func set(_ value: Value) {
        Task { [store, key] in
            await store.set(value, for: key)
        }
    }

    /// Removes the override. ``current`` is updated by the observation
    /// stream once the reset lands, not synchronously here.
    public func reset() {
        Task { [store, key] in
            await store.reset(key)
        }
    }
}
