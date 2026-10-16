import SwiftUI

/// The settings window's sidebar: grouped browse categories, or the flat
/// ranked result list while a query is active, plus the search field.
@MainActor
struct SettingsSidebarList: View {
    @Bindable var query: SettingsSearchQuery
    @Binding var selection: String
    let isCloudSectionAvailable: Bool

    var body: some View {
        List(selection: $selection) {
            SettingsSidebarRows(query: query, isCloudSectionAvailable: isCloudSectionAvailable)
        }
        .listStyle(.sidebar)
        .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
        .searchable(text: $query.text, placement: .sidebar, prompt: Text(String(localized: "settings.search.prompt", defaultValue: "Search")))
        .navigationSplitViewColumnWidth(210)
    }
}

/// The sidebar's rows. Reads only the applied results, never the field
/// text, so a keystroke does not rebuild or diff the list; it changes once
/// per debounced match.
@MainActor
private struct SettingsSidebarRows: View {
    let query: SettingsSearchQuery
    let isCloudSectionAvailable: Bool

    var body: some View {
        let matches = query.results.filter { isEntryVisible($0) }
        if matches.isEmpty {
            Text(String(localized: "settings.search.noResults", defaultValue: "No Results"))
                .foregroundStyle(.secondary)
        } else if query.isShowingSearchResults {
            // Search stays flat and relevance-ranked. Taxonomy only
            // reorganizes the default browse view, so existing setting
            // hit IDs, row anchors, and deep-link selection semantics
            // remain unchanged while a query is active.
            ForEach(matches) { entry in
                entryRow(entry)
            }
        } else {
            ForEach(SettingsTaxonomyGroup.allCases) { group in
                let groupEntries = taxonomyEntries(for: group, from: matches)
                if !groupEntries.isEmpty {
                    Section {
                        ForEach(groupEntries) { entry in
                            entryRow(entry)
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }
        }
    }

    private func isEntryVisible(_ entry: SettingsSearchIndex.Entry) -> Bool {
        guard !isCloudSectionAvailable else { return true }
        switch entry.kind {
        case .section:
            return entry.id != "section:\(SettingsSectionID.cloudMachines.rawValue)"
        case .setting(let parent):
            return parent != .cloudMachines
        }
    }

    /// Renders one existing search-index entry as a selectable sidebar leaf.
    private func entryRow(_ entry: SettingsSearchIndex.Entry) -> some View {
        SettingsSidebarEntryRow(
            title: entry.title,
            symbolName: entry.symbolName,
            subtitle: subtitle(for: entry)
        )
        .tag(entry.id)
    }

    /// Returns the existing section entries in taxonomy order without
    /// changing their ids or targets. Runtime visibility filtering happens
    /// before this step, so unavailable leaves simply disappear from their
    /// group while the remaining destinations keep their stable identities.
    private func taxonomyEntries(
        for group: SettingsTaxonomyGroup,
        from entries: [SettingsSearchIndex.Entry]
    ) -> [SettingsSearchIndex.Entry] {
        group.sections.compactMap { section in
            entries.first { $0.id == "section:\(section.rawValue)" }
        }
    }

    /// Legacy `SettingsSearchEntry` populates `subtitle` with the
    /// parent section's title for setting-type hits and `nil` for
    /// section-type hits, so `SettingsSidebarEntryRow` renders the
    /// section name underneath each search hit but keeps section
    /// rows single-line. Mirror that here.
    private func subtitle(for entry: SettingsSearchIndex.Entry) -> String? {
        switch entry.kind {
        case .section:
            return nil
        case .setting(let parent):
            return parent.title
        }
    }
}
