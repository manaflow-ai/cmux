import CmuxFoundation
import CmuxSettings
import SwiftUI

@MainActor
struct SidebarFontSettingsRows: View {
    @Binding var sidebarFont: SettingsFontSize
    @Binding var fontSaveFailed: Bool
    let sidebarFontFamily: DefaultsValueModel<String>
    let hostActions: SettingsHostActions
    @State private var tasks = MainActorTaskStore<String>()

    var body: some View {
        Group {
            SettingsCardRow(
                configurationReview: .json("sidebarAppearance.fontFamily"),
                String(localized: "settings.sidebarAppearance.fontFamily", defaultValue: "Sidebar Font Family"),
                subtitle: String(localized: "settings.sidebarAppearance.fontFamily.subtitle", defaultValue: "Use an installed font family for built-in workspace titles, details, and badges. Leave empty for the system font."),
                controlWidth: 250
            ) {
                TextField(
                    String(localized: "settings.sidebarAppearance.fontFamily.placeholder", defaultValue: "System font"),
                    text: Binding(
                        get: { sidebarFontFamily.current },
                        set: { sidebarFontFamily.set($0) }
                    ),
                    onCommit: saveFamily
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .accessibilityIdentifier("SettingsSidebarFontFamilyField")
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.sidebarAppearance.fontSize", defaultValue: "Sidebar Font Size"),
                subtitle: String(localized: "settings.sidebarAppearance.fontSize.subtitle", defaultValue: "Controls workspace titles, metadata, badges, and shortcut hints in the left sidebar."),
                controlWidth: 250
            ) {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(get: { sidebarFont.points }, set: { sidebarFont.points = $0 }),
                            in: sidebarFont.minimum...sidebarFont.maximum,
                            step: 0.5
                        ) { editing in
                            if !editing { saveSidebarFontSize(sidebarFont.points) }
                        }
                        .frame(width: 130)
                        .accessibilityIdentifier("SettingsSidebarFontSizeSlider")

                        Text(String.localizedStringWithFormat(String(localized: "settings.fontSize.valuePoints", defaultValue: "%@ pt"), hostActions.formattedFontSize(sidebarFont.points)))
                            .cmuxFont(size: 12, weight: .medium, design: .rounded)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)

                        Button(String(localized: "settings.sidebarAppearance.fontSize.reset", defaultValue: "Reset")) {
                            sidebarFont.points = sidebarFont.defaultValue
                            saveSidebarFontSize(sidebarFont.points)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(sidebarFont.isDefault)
                    }

                    if fontSaveFailed {
                        Text(String(localized: "settings.sidebarAppearance.fontSize.saveFailed", defaultValue: "Couldn't save sidebar font size. Please try again."))
                            .cmuxFont(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .task {
            sidebarFontFamily.startObserving()
        }
    }

    private func saveFamily() {
        sidebarFontFamily.set(sidebarFontFamily.current.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func saveSidebarFontSize(_ points: Double) {
        tasks.replaceOnMainActor("fontSave") {
            let saved = await hostActions.setSidebarFontSize(points)
            if !Task.isCancelled { fontSaveFailed = !saved }
        }
    }
}
