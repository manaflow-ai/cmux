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
/// `values(for:)`, the same wrapper covers UserDefaults- and JSON-backed keys
/// with one code path — no per-host or per-store variants, and no raw
/// `@AppStorage` string keys.
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
/// Writes go through the same store the value is read from, so there is one
/// source of truth. Reads work without an injected ``SettingsRuntime`` (the
/// `@State` is seeded from the catalog default in `init`); the runtime is only
/// needed to observe and persist changes, resolved from the environment.
@MainActor
@propertyWrapper
public struct LiveSetting<Value: SettingCodable>: @preconcurrency DynamicProperty {
    @Environment(\.settingsRuntime) private var runtime
    @State private var value: Value
    @State private var driver = SettingReadDriver<Value>()

    private let kind: Kind

    private enum Kind {
        case defaults(KeyPath<SettingCatalog, DefaultsKey<Value>>)
        case json(KeyPath<SettingCatalog, JSONKey<Value>>)
    }

    /// Binds to a UserDefaults-backed setting.
    public init(_ keyPath: KeyPath<SettingCatalog, DefaultsKey<Value>>) {
        kind = .defaults(keyPath)
        _value = State(initialValue: SettingCatalog()[keyPath: keyPath].defaultValue)
    }

    /// Binds to a JSON-config-backed setting.
    public init(_ keyPath: KeyPath<SettingCatalog, JSONKey<Value>>) {
        kind = .json(keyPath)
        _value = State(initialValue: SettingCatalog()[keyPath: keyPath].defaultValue)
    }

    public var wrappedValue: Value {
        get { value }
        nonmutating set { write(newValue) }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { value }, set: { write($0) })
    }

    public func update() {
        guard let runtime else { return }
        switch kind {
        case .defaults(let keyPath):
            let key = runtime.catalog[keyPath: keyPath]
            driver.activate({ runtime.userDefaultsStore.values(for: key) }, sink: $value)
        case .json(let keyPath):
            let key = runtime.catalog[keyPath: keyPath]
            driver.activate({ runtime.jsonStore.values(for: key) }, sink: $value)
        }
    }

    /// Optimistically updates the local `@State` (immediate UI) and persists to
    /// the backing store. The observation stream yields the committed value
    /// back, reconciling any divergence.
    private func write(_ newValue: Value) {
        value = newValue
        guard let runtime else { return }
        switch kind {
        case .defaults(let keyPath):
            let key = runtime.catalog[keyPath: keyPath]
            Task { await runtime.userDefaultsStore.set(newValue, for: key) }
        case .json(let keyPath):
            let key = runtime.catalog[keyPath: keyPath]
            let errorLog = runtime.errorLog
            Task {
                do { try await runtime.jsonStore.set(newValue, for: key) }
                catch { errorLog.record(error, keyID: key.id) }
            }
        }
    }
}
