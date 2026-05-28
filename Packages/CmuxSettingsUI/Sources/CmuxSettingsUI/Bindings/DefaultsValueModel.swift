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
        self.current = key.defaultValue
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
    /// `Foundation.UserDefaults.set(_:forKey:)` returns `Void` and has no
    /// failure path that the OS surfaces, so there is no async error to
    /// route into an error log. The asymmetry with ``JSONValueModel``
    /// (whose underlying store can `throw`) is intrinsic to the two
    /// backing APIs, not an oversight.
    public func set(_ value: Value) {
        Task { [store, key] in
            await store.set(value, for: key)
        }
    }

    /// Resets the override; the next observed value will be the key's
    /// default.
    public func reset() {
        Task { [store, key] in
            await store.reset(key)
        }
    }
}
