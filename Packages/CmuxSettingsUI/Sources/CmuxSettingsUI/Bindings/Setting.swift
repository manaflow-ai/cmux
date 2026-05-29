import CmuxSettings
import Observation
import SwiftUI

/// Property wrapper that binds a SwiftUI view to one setting in the
/// catalog, regardless of which store backs it.
///
/// Resolves its store + catalog from the injected ``SettingsRuntime`` in
/// the environment, so views never have to take a runtime as an `init`
/// parameter. The keypath determines which store (UserDefaults vs JSON):
/// overloaded inits match `DefaultsKey<V>` and `JSONKey<V>` separately.
///
/// ```swift
/// struct AppearancePicker: View {
///     @Setting(\.app.appearance) var mode
///
///     var body: some View {
///         Picker("Appearance", selection: $mode) {
///             ForEach(AppearanceMode.allCases, id: \.self) { mode in
///                 Text(String(describing: mode)).tag(mode)
///             }
///         }
///     }
/// }
/// ```
///
/// JSON-write failures are routed into the runtime's
/// ``SettingsErrorLog`` so the UI can surface them centrally; the
/// `Binding<Value>` setter itself never throws.
@MainActor
@propertyWrapper
public struct Setting<Value: SettingCodable>: @preconcurrency DynamicProperty {
    @Environment(\.settingsRuntime) private var runtime
    @State private var resolved: ResolvedModel<Value> = .pending

    private let kind: Kind

    private enum Kind {
        case defaults(KeyPath<SettingCatalog, DefaultsKey<Value>>)
        case json(KeyPath<SettingCatalog, JSONKey<Value>>)
    }

    /// Binds to a UserDefaults-backed setting.
    public init(_ keyPath: KeyPath<SettingCatalog, DefaultsKey<Value>>) {
        self.kind = .defaults(keyPath)
    }

    /// Binds to a JSON-config-backed setting.
    public init(_ keyPath: KeyPath<SettingCatalog, JSONKey<Value>>) {
        self.kind = .json(keyPath)
    }

    public var wrappedValue: Value {
        get {
            switch resolved {
            case .pending: return fallbackDefault
            case .defaults(let model): return model.current
            case .json(let model): return model.current
            }
        }
        nonmutating set {
            switch resolved {
            case .pending: return
            case .defaults(let model): model.set(newValue)
            case .json(let model): model.set(newValue)
            }
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }

    public func update() {
        guard case .pending = resolved, let runtime else { return }
        switch kind {
        case .defaults(let keyPath):
            let key = runtime.catalog[keyPath: keyPath]
            resolved = .defaults(DefaultsValueModel(
                store: runtime.userDefaultsStore,
                key: key
            ))
        case .json(let keyPath):
            let key = runtime.catalog[keyPath: keyPath]
            resolved = .json(JSONValueModel(
                store: runtime.jsonStore,
                key: key,
                errorLog: runtime.errorLog
            ))
        }
    }

    private var fallbackDefault: Value {
        // Used only when no runtime is injected (previews, tests).
        guard let runtime else {
            // Re-derive from the keypath against a fresh catalog instance.
            let catalog = SettingCatalog()
            switch kind {
            case .defaults(let kp): return catalog[keyPath: kp].defaultValue
            case .json(let kp): return catalog[keyPath: kp].defaultValue
            }
        }
        switch kind {
        case .defaults(let kp): return runtime.catalog[keyPath: kp].defaultValue
        case .json(let kp): return runtime.catalog[keyPath: kp].defaultValue
        }
    }
}

/// Backing storage for ``Setting``. Boxes whichever model variant the
/// keypath resolved to.
private enum ResolvedModel<Value: SettingCodable>: Sendable {
    case pending
    case defaults(DefaultsValueModel<Value>)
    case json(JSONValueModel<Value>)
}
