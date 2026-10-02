import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// `appearance.theme`: the Ghostty config's theme, the curated themes
/// onboarding offers (`ActionArgument.curatedThemes`), and every other
/// Ghostty theme in a submenu (`SettingsWindowHost.themeNames`). A value
/// typed into cmux.json that is not listed (a light/dark pair, a path)
/// shows as the current item. Theme names are product names and are not
/// translated.
struct AppThemeControl: View {
    let model: SettingsWindowModel
    let descriptor: SettingDescriptor

    var body: some View {
        let current = model.value(descriptor)?.stringValue
        let curated = ActionArgument.curatedThemes
        let others = (model.host?.themeNames ?? []).filter { !curated.contains($0) }
        let unlisted = current.flatMap { curated.contains($0) || others.contains($0) ? nil : $0 }
        Menu {
            item(descriptor.defaultLabel ?? "", selected: current == nil) { model.set(descriptor, nil) }
            Divider()
            ForEach(curated, id: \.self) { name in
                item(name, selected: current == name) { model.set(descriptor, .string(name)) }
            }
            if let unlisted {
                Divider()
                item(unlisted, selected: true) {}
            }
            if !others.isEmpty {
                Divider()
                Menu(SettingsWindowStrings.moreThemes) {
                    ForEach(others, id: \.self) { name in
                        item(name, selected: current == name) { model.set(descriptor, .string(name)) }
                    }
                }
            }
        } label: {
            Text(current ?? descriptor.defaultLabel ?? "")
        }
        .menuStyle(.button)
        .fixedSize()
        .accessibilityIdentifier("cmux.settings.control.\(descriptor.id)")
    }

    private func item(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
