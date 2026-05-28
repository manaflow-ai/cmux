import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Sidebar appearance** subsection.
///
/// Exposes the tint hex inputs and the tint opacity slider. The
/// preset chooser (Native / Translucent / etc.) and the per-light/dark
/// tint inputs live alongside but are still on the legacy code path.
public struct SidebarAppearanceSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            Section("Tint") {
                tintRow(title: "Tint color (#RRGGBB)", key: catalog.sidebarAppearance.tintColorHex)
                tintRow(title: "Light-mode tint (#RRGGBB)", key: catalog.sidebarAppearance.lightModeTintColorHex)
                tintRow(title: "Dark-mode tint (#RRGGBB)", key: catalog.sidebarAppearance.darkModeTintColorHex)
                opacityRow
            }
            Section("Backdrop") {
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.matchTerminalBackground),
                    title: "Match terminal background"
                )
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func tintRow(title: String, key: DefaultsKey<String>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        TextField(title, text: Binding(get: { model.current }, set: { model.set($0) }))
            .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private var opacityRow: some View {
        let model = DefaultsValueModel(
            store: defaultsStore,
            key: catalog.sidebarAppearance.tintOpacity
        )
        VStack(alignment: .leading) {
            HStack {
                Text("Tint opacity")
                Spacer()
                Text(String(format: "%.0f%%", model.current * 100))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(get: { model.current }, set: { model.set($0) }),
                in: 0...1
            )
        }
    }
}
