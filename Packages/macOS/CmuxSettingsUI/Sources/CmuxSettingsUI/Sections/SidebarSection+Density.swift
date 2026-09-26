import CmuxSettings
import SwiftUI

extension SidebarSection {
    var densityRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.density"),
            String(localized: "settings.sidebar.density", defaultValue: "Sidebar Density"),
            subtitle: String(localized: "settings.sidebar.density.subtitle", defaultValue: "Sets which workspace details show by default. Detail toggles you change below keep your choice.")
        ) {
            Picker("", selection: Binding(get: { density.current }, set: { density.set($0) })) {
                ForEach(SidebarDensity.allCases, id: \.self) { value in
                    Text(Self.densityLabel(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("SettingsSidebarDensityPicker")
        }
        .disabled(hideAll.current)
    }

    /// The value a detail toggle shows: its own stored value, or the density
    /// preset when the user never set it.
    func effectiveDetailValue(_ model: DefaultsValueModel<Bool>, key: DefaultsKey<Bool>) -> Bool {
        _ = model.revision
        guard !defaultsStore.initialHasStoredValue(for: key) else { return model.current }
        return density.current.presetValue(forSettingID: key.id) ?? model.current
    }

    func detailToggleBinding(_ model: DefaultsValueModel<Bool>, key: DefaultsKey<Bool>) -> Binding<Bool> {
        Binding(get: { effectiveDetailValue(model, key: key) }, set: { model.set($0) })
    }

    /// The notification preview line limit, following the density when unset.
    var effectiveNotificationMessageLineLimit: Int {
        _ = notificationMessageLineLimit.revision
        let key = catalog.sidebar.notificationMessageLineLimit
        guard !defaultsStore.initialHasStoredValue(for: key) else { return notificationMessageLineLimit.current }
        return density.current.notificationMessageLineLimit ?? notificationMessageLineLimit.current
    }

    nonisolated public static func densityLabel(_ density: SidebarDensity) -> String {
        switch density {
        case .full:
            String(localized: "settings.sidebar.density.full", defaultValue: "Full")
        case .compact:
            String(localized: "settings.sidebar.density.compact", defaultValue: "Compact")
        case .quiet:
            String(localized: "settings.sidebar.density.quiet", defaultValue: "Quiet")
        }
    }
}
