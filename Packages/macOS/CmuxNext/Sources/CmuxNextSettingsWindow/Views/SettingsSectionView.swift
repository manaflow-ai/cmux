import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// One section: its own content (Keyboard, Rooms, Machines, Terminal,
/// Advanced, the theme card), the schema's rows grouped by heading, then
/// the section's actions from the registry.
struct SettingsSectionView: View {
    let model: SettingsWindowModel
    let section: SettingsSection

    var body: some View {
        switch section {
        case .appearance: ThemeCard()
        case .terminal: TerminalInfoCard(model: model)
        case .keyboard: KeyboardSectionView(model: model)
        case .rooms:
            ListSectionCard(rows: model.host?.rooms, empty: SettingsWindowStrings.roomsEmpty,
                            unavailable: SettingsWindowStrings.roomsUnavailable)
            BrowserProfilesCard(model: model)
        case .machines: ListSectionCard(rows: model.host?.machines ?? [], empty: SettingsWindowStrings.machinesEmpty, unavailable: "")
        case .advanced: AdvancedCard(model: model)
        case .general, .browser, .notifications: EmptyView()
        }
        ForEach(model.groups(in: section)) { group in
            SettingsCard(title: group.title) {
                ForEach(group.settings) { SettingRowView(model: model, descriptor: $0) }
            }
        }
        let actions = SettingsSchema.actions(in: section).filter { model.actionTitle($0) != nil }
        if !actions.isEmpty {
            FlowActions(model: model, actions: actions)
        }
    }
}

/// The section's registry actions as a row of buttons.
private struct FlowActions: View {
    let model: SettingsWindowModel
    let actions: [ActionID]

    var body: some View {
        HStack(spacing: Metrics.space4) {
            ForEach(actions, id: \.self) { id in
                Button(model.actionTitle(id) ?? id.rawValue) { model.perform(id) }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(!model.registry.isAvailable(id))
                    .accessibilityIdentifier("cmux.settings.action.\(id.rawValue)")
            }
        }
    }
}
