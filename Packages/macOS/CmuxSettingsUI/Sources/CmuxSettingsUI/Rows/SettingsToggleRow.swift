import CmuxFoundation
import CmuxSettings
import SwiftUI

/// A labeled SwiftUI `Toggle` bound to a `Bool` ``DefaultsKey`` via a
/// ``DefaultsValueModel``.
///
/// Encapsulates the per-row layout cmux uses across its settings panes:
/// title on the left, optional subtitle/secondary text underneath,
/// `Toggle` on the right.
///
/// ```swift
/// SettingsToggleRow(
///     model: DefaultsValueModel(store: defaultsStore, key: catalog.app.warnBeforeQuit),
///     title: "Warn before quitting",
///     subtitle: "Show a confirmation when ⌘Q is pressed with active workspaces."
/// )
/// ```
@MainActor
public struct SettingsToggleRow: View {
    private let model: DefaultsValueModel<Bool>
    private let title: String
    private let subtitle: String?

    public init(
        model: DefaultsValueModel<Bool>,
        title: String,
        subtitle: String? = nil
    ) {
        self.model = model
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        Toggle(isOn: Binding(
            get: { model.current },
            set: { model.set($0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { model.startObserving() }
    }
}
