import SwiftUI

extension SettingsWindowRoot {
    @ViewBuilder
    var sidebar: some View {
        List(selection: sidebarSelectionBinding) {
            let matches = sidebarEntries(matching: settingsSearchText).filter(isEntryVisible)
            if matches.isEmpty {
                Text(String(localized: "settings.search.noResults", defaultValue: "No Results"))
                    .foregroundStyle(chromePalette.textSecondary.swiftUIColor)
            } else {
                ForEach(matches) { entry in
                    SettingsSidebarEntryRow(
                        title: entry.title,
                        symbolName: entry.symbolName,
                        subtitle: subtitle(for: entry)
                    )
                    .tag(entry.id)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(chromePalette.surface.swiftUIColor)
        .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
        .searchable(
            text: settingsSearchTextBinding,
            placement: .sidebar,
            prompt: Text(String(localized: "settings.search.prompt", defaultValue: "Search"))
        )
        .navigationSplitViewColumnWidth(210)
    }
}
