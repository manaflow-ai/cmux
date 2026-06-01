import CmuxSettings
import SwiftUI

/// Property wrapper that binds a SwiftUI view to one catalog setting, holding
/// the latest value in its own `@State` so it stays reactive in **any** host —
/// including the main window's AppKit `NSHostingView`, where ``Setting`` does
/// not re-render on external changes.
///
/// ``Setting`` reads through an `@Observable` model whose value is updated from
/// the store's `AsyncStream`; SwiftUI's Observation does not re-invalidate an
/// `NSHostingView`-hosted subtree for that off-render update. ``LiveSetting``
/// removes that dependency: a ``SettingReadDriver`` forwards the store's
/// `values(for:)` stream into a private `@State`, so re-rendering rides on
/// `@State` invalidation (host-agnostic). Because every store exposes
/// `values(for:)`, one wrapper covers UserDefaults-, JSON-, and secret-backed
/// keys with a single code path and no raw `@AppStorage` string keys.
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
@MainActor
@propertyWrapper
public struct LiveSetting<Value: SettingCodable>: @preconcurrency DynamicProperty {
    @Environment(\.settingsRuntime) private var runtime
    @State private var value: Value
    @State private var driver = SettingReadDriver<Value>()

    /// Builds the change stream for this key against a resolved runtime.
    private let makeStream: (SettingsRuntime) -> AsyncStream<Value>
    /// Persists a new value to the backing store for this key.
    private let persist: (SettingsRuntime, Value) -> Void

    /// Binds to a UserDefaults-backed setting.
    public init(_ keyPath: KeyPath<SettingCatalog, DefaultsKey<Value>>) {
        _value = State(initialValue: SettingCatalog()[keyPath: keyPath].defaultValue)
        makeStream = { runtime in
            runtime.userDefaultsStore.values(for: runtime.catalog[keyPath: keyPath])
        }
        persist = { runtime, newValue in
            let key = runtime.catalog[keyPath: keyPath]
            Task { await runtime.userDefaultsStore.set(newValue, for: key) }
        }
    }

    /// Binds to a JSON-config-backed setting.
    public init(_ keyPath: KeyPath<SettingCatalog, JSONKey<Value>>) {
        _value = State(initialValue: SettingCatalog()[keyPath: keyPath].defaultValue)
        makeStream = { runtime in
            runtime.jsonStore.values(for: runtime.catalog[keyPath: keyPath])
        }
        persist = { runtime, newValue in
            let key = runtime.catalog[keyPath: keyPath]
            let errorLog = runtime.errorLog
            Task {
                do { try await runtime.jsonStore.set(newValue, for: key) }
                catch { errorLog.record(error, keyID: key.id) }
            }
        }
    }

    /// Binds to a secret-file-backed setting. Secrets are always strings, so
    /// this overload is only available when `Value` is `String`; with that
    /// constraint in scope the secret store's `AsyncStream<String>` is an
    /// `AsyncStream<Value>` directly.
    public init(_ keyPath: KeyPath<SettingCatalog, SecretFileKey>) where Value == String {
        _value = State(initialValue: SettingCatalog()[keyPath: keyPath].defaultValue)
        makeStream = { runtime in
            runtime.secretStore.values(for: runtime.catalog[keyPath: keyPath])
        }
        persist = { runtime, newValue in
            let key = runtime.catalog[keyPath: keyPath]
            let errorLog = runtime.errorLog
            Task {
                do { try await runtime.secretStore.set(newValue, for: key) }
                catch { errorLog.record(error, keyID: key.id) }
            }
        }
    }

    public var wrappedValue: Value {
        get { value }
        nonmutating set {
            // Optimistic local update (immediate UI); persist to the store, which
            // yields the committed value back through the stream and reconciles.
            value = newValue
            if let runtime { persist(runtime, newValue) }
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { value }, set: { wrappedValue = $0 })
    }

    public func update() {
        guard let runtime else { return }
        driver.activate({ makeStream(runtime) }, sink: $value)
    }
}
