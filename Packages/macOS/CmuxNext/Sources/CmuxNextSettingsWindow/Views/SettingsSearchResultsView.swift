import CmuxNextSettings
import SwiftUI

/// Matching settings from every section, then matching shortcuts.
struct SettingsSearchResultsView: View {
    let model: SettingsWindowModel

    var body: some View {
        let groups = model.searchResults()
        let shortcuts = model.shortcutSections()
        if groups.isEmpty, shortcuts.isEmpty {
            Text(SettingsWindowStrings.noResults).foregroundStyle(SettingsStyle.secondary)
        }
        ForEach(groups) { group in
            SettingsCard(title: group.title) {
                ForEach(group.settings) { SettingRowView(model: model, descriptor: $0) }
            }
        }
        if !shortcuts.isEmpty {
            KeyboardShortcutList(model: model, sections: shortcuts, prefix: SettingsSection.keyboard.title)
        }
    }
}
