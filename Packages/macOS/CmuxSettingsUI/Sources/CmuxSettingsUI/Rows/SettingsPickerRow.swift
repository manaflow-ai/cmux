import CmuxSettings
import SwiftUI

/// A labeled SwiftUI `Picker` bound to an enum ``DefaultsKey`` via a
/// ``DefaultsValueModel``.
///
/// `Value` is constrained to `CaseIterable & Hashable` so the picker can
/// enumerate options. The caller supplies a display-label function so the
/// raw value's name isn't bare in the UI.
///
/// ```swift
/// SettingsPickerRow(
///     model: DefaultsValueModel(store: defaults, key: catalog.app.appearance),
///     title: "Appearance",
///     label: { mode in
///         switch mode {
///         case .system: return "Follow System"
///         case .light:  return "Light"
///         case .dark:   return "Dark"
///         }
///     }
/// )
/// ```
@MainActor
public struct SettingsPickerRow<Value: SettingCodable & CaseIterable & Hashable>: View
where Value.AllCases: RandomAccessCollection {
    private let model: DefaultsValueModel<Value>
    private let title: String
    private let label: (Value) -> String

    public init(
        model: DefaultsValueModel<Value>,
        title: String,
        label: @escaping (Value) -> String
    ) {
        self.model = model
        self.title = title
        self.label = label
    }

    public var body: some View {
        Picker(title, selection: Binding(
            get: { model.current },
            set: { model.set($0) }
        )) {
            ForEach(Value.allCases, id: \.self) { value in
                Text(label(value)).tag(value)
            }
        }
        .task { model.startObserving() }
    }
}
