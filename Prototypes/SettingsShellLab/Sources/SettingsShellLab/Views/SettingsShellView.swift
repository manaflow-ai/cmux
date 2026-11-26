import SwiftUI

struct SettingsShellView: View {
    @SceneStorage("selectedSettingsSection") private var selectedSectionRaw = SettingsSection.general.rawValue
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var searchText = ""

    private var selectedSection: SettingsSection {
        SettingsSection(rawValue: selectedSectionRaw) ?? .general
    }

    private var filteredSections: [SettingsSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { section in
            section.searchText.localizedStandardContains(query)
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selectedSectionRaw) {
                ForEach(filteredSections) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section.rawValue)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(String(localized: "settings.sidebar.title", defaultValue: "Settings"))
            .searchable(
                text: $searchText,
                placement: .sidebar,
                prompt: Text(String(localized: "settings.search.prompt", defaultValue: "Search"))
            )
            .navigationSplitViewColumnWidth(210)
        } detail: {
            SettingsDetailView(section: selectedSection)
        }
        .navigationSplitViewStyle(.balanced)
    }
}
