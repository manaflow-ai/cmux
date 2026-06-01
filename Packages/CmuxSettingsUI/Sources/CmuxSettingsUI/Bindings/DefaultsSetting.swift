import CmuxSettings
import SwiftUI

/// Property wrapper that binds a SwiftUI view to one UserDefaults-backed
/// setting in the catalog, using `@AppStorage` for storage and observation.
///
/// This is the sibling of ``Setting`` for views that live outside a reliable
/// ``SettingsRuntime`` environment — most importantly the main window, whose
/// `ContentView` is hosted by an AppKit `NSHostingView` that does not inherit
/// the App scene's environment. ``Setting`` resolves its value from the
/// injected runtime and, in that AppKit-hosted subtree, does not re-render on
/// external changes; `@AppStorage` does, because SwiftUI special-cases its
/// `UserDefaults` observation in hosting views. ``DefaultsSetting`` keeps the
/// ergonomics and single-source-of-truth of ``Setting`` (you pass a catalog
/// key path, never a raw string) while inheriting `@AppStorage`'s reactivity.
///
/// The catalog ``DefaultsKey`` remains the one definition of the storage key,
/// default value, and suite; this wrapper only reads them from it.
///
/// ```swift
/// struct SidebarFooter: View {
///     @DefaultsSetting(\.betaFeatures.extensions) private var extensionsEnabled
///
///     var body: some View {
///         if extensionsEnabled { PuzzleButton() }
///     }
/// }
/// ```
///
/// Use ``Setting`` in the Settings window and other views mounted directly in
/// the App scene; use ``DefaultsSetting`` for UserDefaults-backed settings read
/// inside the AppKit-hosted main window. Only the value types `@AppStorage`
/// supports natively are available (`Bool`, `Int`, `Double`, `String`, and
/// `RawRepresentable` with an `Int` or `String` raw value); JSON- and
/// secret-backed keys have no `@AppStorage` equivalent and stay on ``Setting``.
@MainActor
@propertyWrapper
public struct DefaultsSetting<Value>: DynamicProperty where Value: SettingCodable {
    /// Backing `@AppStorage`. Constructed from the catalog key in `init`, it
    /// drives observation; SwiftUI updates this nested `DynamicProperty`
    /// automatically.
    private var storage: AppStorage<Value>

    public var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    /// A two-way binding to the setting, e.g. for a `Toggle`.
    public var projectedValue: Binding<Value> { storage.projectedValue }
}

private func resolvedStore<V>(for key: DefaultsKey<V>) -> UserDefaults? {
    // nil tells @AppStorage to use UserDefaults.standard, which is the suite
    // the app's settings store is built on; honor an explicit suite if set.
    key.suite.flatMap(UserDefaults.init(suiteName:))
}

public extension DefaultsSetting {
    /// Binds to a `Bool` setting.
    init(_ keyPath: KeyPath<SettingCatalog, DefaultsKey<Value>>) where Value == Bool {
        let key = SettingCatalog()[keyPath: keyPath]
        storage = AppStorage(wrappedValue: key.defaultValue, key.userDefaultsKey, store: resolvedStore(for: key))
    }

    /// Binds to an `Int` setting.
    init(_ keyPath: KeyPath<SettingCatalog, DefaultsKey<Value>>) where Value == Int {
        let key = SettingCatalog()[keyPath: keyPath]
        storage = AppStorage(wrappedValue: key.defaultValue, key.userDefaultsKey, store: resolvedStore(for: key))
    }

    /// Binds to a `Double` setting.
    init(_ keyPath: KeyPath<SettingCatalog, DefaultsKey<Value>>) where Value == Double {
        let key = SettingCatalog()[keyPath: keyPath]
        storage = AppStorage(wrappedValue: key.defaultValue, key.userDefaultsKey, store: resolvedStore(for: key))
    }

    /// Binds to a `String` setting.
    init(_ keyPath: KeyPath<SettingCatalog, DefaultsKey<Value>>) where Value == String {
        let key = SettingCatalog()[keyPath: keyPath]
        storage = AppStorage(wrappedValue: key.defaultValue, key.userDefaultsKey, store: resolvedStore(for: key))
    }

    /// Binds to a `RawRepresentable` setting whose raw value is an `Int`.
    init(_ keyPath: KeyPath<SettingCatalog, DefaultsKey<Value>>) where Value: RawRepresentable, Value.RawValue == Int {
        let key = SettingCatalog()[keyPath: keyPath]
        storage = AppStorage(wrappedValue: key.defaultValue, key.userDefaultsKey, store: resolvedStore(for: key))
    }

    /// Binds to a `RawRepresentable` setting whose raw value is a `String`.
    init(_ keyPath: KeyPath<SettingCatalog, DefaultsKey<Value>>) where Value: RawRepresentable, Value.RawValue == String {
        let key = SettingCatalog()[keyPath: keyPath]
        storage = AppStorage(wrappedValue: key.defaultValue, key.userDefaultsKey, store: resolvedStore(for: key))
    }
}
