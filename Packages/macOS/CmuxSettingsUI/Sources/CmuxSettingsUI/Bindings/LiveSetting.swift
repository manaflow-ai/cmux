import CmuxSettings
import SwiftUI

/// Immutable catalog metadata shared by every wrapper instance. Constructing
/// the full catalog for each transient SwiftUI view value allocates every key
/// and JSON path even though a wrapper resolves only one key path.
private let liveSettingCatalog = SettingCatalog()

/// Property wrapper that binds a SwiftUI view to one catalog setting, holding
/// the latest value in its own `@State` so it stays reactive in **any** host —
/// including the main window's AppKit `NSHostingView`.
///
/// A settings binding backed by an `@Observable` model whose value is updated
/// from the store's `AsyncStream` does not re-invalidate an
/// `NSHostingView`-hosted subtree on that off-render update (SwiftUI's
/// Observation doesn't drive the host's redraw there). ``LiveSetting`` removes
/// that dependency: a ``SettingReadDriver`` forwards the store's `values(for:)`
/// stream into a private `@State`, so re-rendering rides on `@State`
/// invalidation (host-agnostic). Because every store exposes `values(for:)`,
/// one wrapper covers UserDefaults-, JSON-, and secret-backed keys with a
/// single code path and no raw `@AppStorage` string keys.
///
/// You always pass a catalog key path, so the catalog stays the single
/// definition of the key, default, and storage:
///
/// ```swift
/// struct SidebarFooter: View {
///     @LiveSetting(\.betaFeatures.extensions) private var extensionsEnabled
///     var body: some View { if extensionsEnabled { PuzzleButton() } }
/// }
/// ```
///
/// Each `init` captures the store's `values(for:)` and `set(_:for:)` for its key
/// kind as closures — done there because that is where the key-kind type
/// information (e.g. a secret's `Value == String`) is in scope, so the secret
/// store's `AsyncStream<String>` is used directly as `AsyncStream<Value>` with
/// no wrapping or casting. Reads work without an injected ``SettingsRuntime``
/// (the `@State` is seeded from the catalog default); the runtime is only
/// needed to observe and persist changes, resolved from the environment.
@propertyWrapper
public struct LiveSetting<Value: SettingCodable>: DynamicProperty {
    @Environment(\.settingsRuntime) private var runtime
    @State private var value: Value
    // SwiftUI recreates DynamicProperty values during diffing. Keep the
    // heavyweight stream owner nil in discarded candidates and allocate it
    // only after SwiftUI installs this wrapper's persistent State storage.
    @State private var driver: SettingReadDriver<Value>?

    /// Builds the change stream for this key against a resolved runtime.
    private let makeStream: @Sendable (SettingsRuntime) -> AsyncStream<Value>
    /// Persists a new value to the backing store for this key.
    private let persist: @Sendable (SettingsRuntime, Value) -> Void

    /// Binds to a UserDefaults-backed setting.
    ///
    /// - Parameter keyPath: Key path to the catalog's ``DefaultsKey`` for this value.
    public init(_ keyPath: KeyPath<SettingCatalog, DefaultsKey<Value>>) {
        let key = liveSettingCatalog[keyPath: keyPath]
        _value = State(initialValue: key.defaultValue)
        makeStream = { runtime in
            runtime.userDefaultsStore.values(for: key)
        }
        persist = { runtime, newValue in
            Task { @MainActor in await runtime.userDefaultsStore.set(newValue, for: key) }
        }
    }

    /// Binds to a JSON-config-backed setting.
    ///
    /// - Parameter keyPath: Key path to the catalog's ``JSONKey`` for this value.
    public init(_ keyPath: KeyPath<SettingCatalog, JSONKey<Value>>) {
        let key = liveSettingCatalog[keyPath: keyPath]
        _value = State(initialValue: key.defaultValue)
        makeStream = { runtime in
            runtime.jsonStore.values(for: key)
        }
        persist = { runtime, newValue in
            let errorLog = runtime.errorLog
            Task { @MainActor in
                do { try await runtime.jsonStore.set(newValue, for: key) }
                catch { errorLog.record(error, keyID: key.id) }
            }
        }
    }

    /// Binds to a secret-file-backed setting. Secrets are always strings, so
    /// this overload is only available when `Value` is `String`; with that
    /// constraint in scope the secret store's `AsyncStream<String>` is an
    /// `AsyncStream<Value>` directly.
    ///
    /// - Parameter keyPath: Key path to the catalog's ``SecretFileKey``.
    public init(_ keyPath: KeyPath<SettingCatalog, SecretFileKey>) where Value == String {
        let key = liveSettingCatalog[keyPath: keyPath]
        _value = State(initialValue: key.defaultValue)
        makeStream = { runtime in
            runtime.secretStore.values(for: key)
        }
        persist = { runtime, newValue in
            let errorLog = runtime.errorLog
            Task { @MainActor in
                do { try await runtime.secretStore.set(newValue, for: key) }
                catch { errorLog.record(error, keyID: key.id) }
            }
        }
    }

    /// The current setting value.
    ///
    /// Reads return the latest value the observation stream has delivered into
    /// the wrapper's `@State`. Writes persist to the backing store and do not
    /// update `@State` directly; the stream yields the committed value back, so
    /// a write that the store rejects leaves the displayed value unchanged.
    @MainActor public var wrappedValue: Value {
        get { value }
        nonmutating set {
            // Persist only; the observation stream is the single writer of
            // `value`, so the UI reflects the change once the write commits and
            // the stream yields it back (a small storage round-trip). A failed
            // JSON/secret write therefore leaves `value` at the last committed
            // value instead of stranding an unsaved one. Mirrors DefaultsValueModel.
            if let runtime { persist(runtime, newValue) }
        }
    }

    /// A two-way `Binding` to the setting, e.g. for a `Toggle` or `TextField`.
    ///
    /// The getter reflects the current `@State` value; the setter persists
    /// through ``wrappedValue``.
    @MainActor public var projectedValue: Binding<Value> {
        Binding(get: { value }, set: { wrappedValue = $0 })
    }

    /// Nonisolated `DynamicProperty` hook. On the first call with a resolved
    /// ``SettingsRuntime`` it starts the ``SettingReadDriver`` that forwards the
    /// store's change stream into the wrapper's `@State`; later calls are no-ops.
    /// SwiftUI's protocol requirement is nonisolated, so this conformance must
    /// not use `@preconcurrency`: doing so synthesizes a runtime MainActor
    /// executor check on every view update.
    public func update() {
        guard let runtime else { return }
        let activeDriver: SettingReadDriver<Value>
        if let driver {
            activeDriver = driver
        } else {
            let newDriver = SettingReadDriver<Value>()
            driver = newDriver
            activeDriver = newDriver
        }
        let binding = $value
        activeDriver.activate({ makeStream(runtime) }) { binding.wrappedValue = $0 }
    }
}
