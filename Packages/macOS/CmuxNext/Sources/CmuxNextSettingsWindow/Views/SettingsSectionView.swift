import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// One section: its own content (Keyboard, Rooms, Machines, Terminal,
/// Advanced, the theme card), the schema's rows grouped by heading, then
/// the section's actions from the registry. Leading groups (the app theme,
/// the terminal font) come before the section's own content.
struct SettingsSectionView: View {
    let model: SettingsWindowModel
    let section: SettingsSection

    var body: some View {
        let groups = model.groups(in: section)
        let leading = groups.filter { Self.leads($0, in: section) }
        ForEach(leading) { GroupCard(model: model, group: $0) }
        switch section {
        case .appearance:
            ThemeCard()
            ThemePickerCard(model: model)
        case .terminal: TerminalInfoCard(model: model)
        case .keyboard: KeyboardSectionView(model: model)
        case .rooms:
            ListSectionCard(rows: model.host?.rooms, empty: SettingsWindowStrings.roomsEmpty,
                            unavailable: SettingsWindowStrings.roomsUnavailable)
            BrowserProfilesCard(model: model)
        case .machines: ListSectionCard(rows: model.host?.machines ?? [], empty: SettingsWindowStrings.machinesEmpty, unavailable: "")
        case .advanced: AdvancedCard(model: model)
        case .accounts:
            if let accounts = model.host?.accountsView(tokens: SettingsTheme.shared.tokens) { accounts }
        case .general, .browser, .notifications: EmptyView()
        }
        ForEach(groups.filter { !leading.contains($0) }) { GroupCard(model: model, group: $0) }
        let actions = SettingsSchema.actions(in: section).filter { model.actionTitle($0) != nil }
        if !actions.isEmpty {
            FlowActions(model: model, actions: actions)
        }
    }

    /// Whether `group` goes above the section's own content: the most-used
    /// rows (plans/cmux-next/settings-ia.md), the app theme on Appearance
    /// and the font on Terminal.
    static func leads(_ group: SettingsGroup, in section: SettingsSection) -> Bool {
        switch section {
        case .appearance: group.settings.contains { $0.path == AppThemeSetting.configPath }
        case .terminal: true
        default: false
        }
    }
}

/// One heading and its rows.
private struct GroupCard: View {
    let model: SettingsWindowModel
    let group: SettingsGroup

    var body: some View {
        SettingsCard(title: group.title) {
            ForEach(group.settings) { SettingRowView(model: model, descriptor: $0) }
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
