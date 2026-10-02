import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// One section: its own content (Keyboard, Rooms, Machines, Terminal,
/// Advanced, the theme card), the schema's rows grouped by heading, then
/// the section's actions from the registry. Leading groups (the app theme,
/// the terminal font) come before the section's own content. Every row,
/// card and button is a jump target (`SettingsAnchorView`); on the one
/// page, `filter` keeps only the matching ones and drops groups left empty.
struct SettingsSectionView: View {
    let model: SettingsWindowModel
    let section: SettingsSection
    /// The one page's search; nil shows everything.
    var filter: SettingsPageFilter?

    var body: some View {
        let highlighted = model.highlighted
        let groups = model.groups(in: section, filter: filter)
        let leading = groups.filter { Self.leads($0, in: section) }
        ForEach(leading) { GroupCard(model: model, group: $0, highlighted: highlighted) }
        SettingsSectionCards(model: model, section: section, filter: filter, highlighted: highlighted)
        ForEach(groups.filter { !leading.contains($0) }) { GroupCard(model: model, group: $0, highlighted: highlighted) }
        let actions = model.actions(in: section, filter: filter)
        if !actions.isEmpty {
            FlowActions(model: model, section: section, actions: actions, highlighted: highlighted)
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

/// One heading and its rows, each a jump target.
private struct GroupCard: View {
    let model: SettingsWindowModel
    let group: SettingsGroup
    let highlighted: String?

    var body: some View {
        SettingsCard(title: group.title) {
            ForEach(group.settings) { descriptor in
                SettingsAnchorView(id: descriptor.id, isHighlighted: highlighted == descriptor.id, spacing: 0) {
                    SettingRowView(model: model, descriptor: descriptor)
                }
            }
        }
    }
}

/// The section's custom cards, each a jump target search indexes
/// (`SettingsCardID`).
private struct SettingsSectionCards: View {
    let model: SettingsWindowModel
    let section: SettingsSection
    let filter: SettingsPageFilter?
    let highlighted: String?

    var body: some View {
        switch section {
        case .appearance:
            anchored(.theme) {
                ThemeCard()
                ThemePickerCard(model: model)
            }
        case .terminal: anchored(.terminal) { TerminalInfoCard(model: model) }
        case .keyboard: KeyboardSectionView(model: model)
        case .rooms:
            anchored(.rooms) {
                ListSectionCard(rows: model.host?.rooms, empty: SettingsWindowStrings.roomsEmpty,
                                unavailable: SettingsWindowStrings.roomsUnavailable)
            }
            anchored(.browserProfiles) { BrowserProfilesCard(model: model) }
        case .machines:
            anchored(.machines) {
                ListSectionCard(rows: model.host?.machines ?? [], empty: SettingsWindowStrings.machinesEmpty, unavailable: "")
            }
        case .advanced: anchored(.advanced) { AdvancedCard(model: model) }
        case .accounts:
            if let accounts = model.host?.accountsView(tokens: SettingsTheme.shared.tokens) {
                anchored(.accounts) { accounts }
            }
        case .general, .browser, .notifications: EmptyView()
        }
    }

    @ViewBuilder
    private func anchored<Content: View>(_ card: SettingsCardID, @ViewBuilder content: () -> Content) -> some View {
        if model.shows(card, filter: filter) {
            SettingsAnchorView(id: card.anchorID, isHighlighted: highlighted == card.anchorID) { content() }
        }
    }
}

/// The section's registry actions as a row of buttons.
private struct FlowActions: View {
    let model: SettingsWindowModel
    let section: SettingsSection
    let actions: [ActionID]
    let highlighted: String?

    var body: some View {
        HStack(spacing: Metrics.space4) {
            ForEach(actions, id: \.self) { id in
                let anchor = SettingsAnchor.action(id, in: section).id
                SettingsAnchorView(id: anchor, isHighlighted: highlighted == anchor, spacing: 0) {
                    Button(model.actionTitle(id) ?? id.rawValue) { model.perform(id) }
                        .buttonStyle(SettingsButtonStyle())
                        .disabled(!model.registry.isAvailable(id))
                        .accessibilityIdentifier("cmux.settings.action.\(id.rawValue)")
                }
            }
        }
    }
}
