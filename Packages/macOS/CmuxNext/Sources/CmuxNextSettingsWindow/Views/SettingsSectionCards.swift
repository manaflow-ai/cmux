import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// The section's custom cards, each a jump target search indexes
/// (`SettingsCardID`).
struct SettingsSectionCards: View {
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
                BackdropPickerCard(model: model)
                BackdropArtAttributionView()
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
        case .general, .browser, .home, .notifications: EmptyView()
        }
    }

    @ViewBuilder
    private func anchored<Content: View>(_ card: SettingsCardID, @ViewBuilder content: () -> Content) -> some View {
        if model.shows(card, filter: filter) {
            SettingsAnchorView(id: card.anchorID, isHighlighted: highlighted == card.anchorID) { content() }
        }
    }
}
