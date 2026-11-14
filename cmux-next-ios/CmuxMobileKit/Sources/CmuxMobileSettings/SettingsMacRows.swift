#if os(iOS)
import CmuxMobileDesign
import SwiftUI


/// The account's Cloud pages Settings lists (Cloud Machines, Automations) and its Connect GitHub
/// row. They come from the Chief module, which holds the account's Cloud calls; Settings only places them.
public struct SettingsCloudPages {
    public var machines: () -> AnyView
    public var automations: () -> AnyView
    public var connectGitHub: () -> AnyView

    public init(machines: @escaping () -> AnyView, automations: @escaping () -> AnyView, connectGitHub: @escaping () -> AnyView) {
        self.machines = machines
        self.automations = automations
        self.connectGitHub = connectGitHub
    }
}

/// Settings → Long-Press Menus (the Mac's Customize Right-Click Menus…): each menu's items,
/// on or off. Close Workspace and the Chief's own rows always stay.
struct LongPressMenusPage: View {
    @State private var hidden = CmuxMobileMenuCustomization.hidden()

    var body: some View {
        List {
            ForEach(CmuxMobileMenuCustomization.menus) { menu in
                Section(menu.title) {
                    ForEach(menu.items) { item in
                        Toggle(isOn: Binding(get: { !hidden.contains(item.id) }, set: { shown in
                            CmuxMobileMenuCustomization.setShown(shown, item.id)
                            hidden = CmuxMobileMenuCustomization.hidden()
                        })) {
                            SettingsLabel(verbatim: item.title, symbol: item.systemImage)
                        }
                        .accessibilityIdentifier("settings.menus.\(item.id)")
                    }
                }
            }
            Section {
                Button("Show All Items") {
                    CmuxMobileMenuCustomization.reset()
                    hidden = []
                }
                .disabled(hidden.isEmpty)
                .accessibilityIdentifier("settings.menus.reset")
            } footer: {
                Text("Items you turn off leave the long-press menu on this iPhone. The Mac's menus stay as they are.")
            }
        }
        .settingsPage("Long-Press Menus")
    }
}

#endif
