import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Workspace Colors** section.
///
/// Indicator style + hex inputs for selection and notification badge. The
/// palette editor (named-color list with custom additions) is still on
/// the legacy code path; this view exposes only the inputs that map
/// cleanly to single-value keys.
public struct WorkspaceColorsSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            Section("Indicator") {
                SettingsPickerRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.indicatorStyle),
                    title: "Active-workspace indicator",
                    label: { style in
                        switch style {
                        case .leftRail: return "Left rail"
                        case .solidFill: return "Solid fill"
                        }
                    }
                )
            }
            Section("Colors") {
                TextField("Selection color (#RRGGBB)", text: hexBinding(catalog.workspaceColors.selectionColorHex))
                    .textFieldStyle(.roundedBorder)
                TextField("Notification badge color (#RRGGBB)", text: hexBinding(catalog.workspaceColors.notificationBadgeColorHex))
                    .textFieldStyle(.roundedBorder)
            }
        }
        .formStyle(.grouped)
    }

    private func hexBinding(_ key: DefaultsKey<String>) -> Binding<String> {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        return Binding(
            get: { model.current },
            set: { model.set($0) }
        )
    }
}
