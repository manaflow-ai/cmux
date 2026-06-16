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
/// Lifecycle: the observation is owned by a ``SettingReadDriver`` held by the
/// model. When the model deallocates, the driver's `deinit` cancels the
/// iterating task, which finishes the change stream and tears down its
/// underlying `NotificationCenter.notifications(named:)` sequence. A bare
/// `weak self` inside the loop is **not** enough — the task is parked at the
/// `await` and never re-checks `self` for an idle key, leaking the
/// subscription (see https://github.com/manaflow-ai/cmux/issues/5302).
@MainActor
@Observable
public final class DefaultsValueModel<Value: SettingCodable> {
    /// The most recently observed value. SwiftUI views read this synchronously.
    public private(set) var current: Value

    private let store: UserDefaultsSettingsStore
    private let key: DefaultsKey<Value>

    /// Owns the change-stream subscription and cancels it when this model
    /// deallocates.
    @ObservationIgnored private let observation = SettingReadDriver<Value>()

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
        observation.activate(makeStream) { [weak self] value in
            self?.current = value
        }
    }

    /// Persists the value. The observation stream is the single writer of
    /// ``current`` for external changes, but direct UI writes update it
    /// optimistically before the async storage write. Synchronous because
    /// SwiftUI `Binding` setters can't `await`; the write itself runs in a
    /// fire-and-forget `Task`.
    public func set(_ value: Value) {
        current = value
        Task { [store, key] in
            await store.set(value, for: key)
        }
    }

    /// Updates ``current`` after another owner has already persisted `value`.
    ///
    /// Use this for settings whose committed write spans multiple backing keys
    /// and must stay in one host-owned mutation path. Unlike ``set(_:)``, this
    /// method does not write to ``store``.
    public func acceptCommittedValue(_ value: Value) {
        current = value
    }

    /// Removes the override; ``current`` updates when the stream observes
    /// the reset.
    public func reset() {
        current = key.defaultValue
        Task { [store, key] in
            await store.reset(key)
        }
    }
}
