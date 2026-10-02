import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// Pages layout search: per section, the matching settings (still
/// editable), then its matching cards and buttons, then matching shortcuts.
/// Every title is a link that opens the result on its page, scrolled into
/// view and highlighted; Return in the search field opens the first one.
struct SettingsSearchResultsView: View {
    let model: SettingsWindowModel

    var body: some View {
        let sections = model.searchResultSections()
        let shortcuts = model.shortcutSections()
        if sections.isEmpty, shortcuts.isEmpty {
            Text(SettingsWindowStrings.noResults).foregroundStyle(SettingsStyle.secondary)
        }
        ForEach(sections) { result in
            ForEach(result.groups) { group in
                SettingsCard(title: group.title) {
                    ForEach(group.settings) { descriptor in
                        SettingRowView(model: model, descriptor: descriptor, onOpen: { model.open(.setting(descriptor)) })
                    }
                }
            }
            if !result.others.isEmpty {
                SettingsCard(title: result.section.title) {
                    ForEach(result.others) { entry in
                        SettingsSearchEntryRow(entry: entry) { model.open(entry.anchor) }
                    }
                }
            }
        }
        if !shortcuts.isEmpty {
            KeyboardShortcutList(model: model, sections: shortcuts, prefix: SettingsSection.keyboard.title)
        }
    }
}

/// A matching card or button: its title links to it on its page.
private struct SettingsSearchEntryRow: View {
    let entry: SettingsSearchEntry
    let open: () -> Void

    var body: some View {
        HStack(spacing: Metrics.space4) {
            SettingsJumpTitle(title: entry.title, action: open)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.space5)
        .frame(minHeight: SettingsStyle.rowHeight)
        .accessibilityIdentifier("cmux.settings.result.\(entry.id)")
    }
}
