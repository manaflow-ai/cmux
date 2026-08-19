import SwiftUI

/// Chrome row shown for every Vault grouping: session search field
/// plus sort and filter menus. Mounted directly by `SessionIndexView` above
/// the table boundary, mirroring the existing control bar (safe to observe
/// the store here — never inside table rows).
struct VaultAllSessionsBar: View {
    @ObservedObject var store: SessionIndexStore
    let chromeBackgroundColor: NSColor
    /// Sort and filters act on the recency ("All") sections; other groupings
    /// keep only the search field.
    let showsSortAndFilter: Bool
    @Binding var searchText: String
    /// Enter — peek the top search result.
    let onPeekTopResult: () -> Void
    /// Cmd+Enter — resume the top search result.
    let onResumeTopResult: () -> Void

    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            searchField
            if showsSortAndFilter {
                sortMenu
                filterMenu
            }
        }
        .rightSidebarChromeBar()
        .rightSidebarChromeBottomBorder(backgroundColor: chromeBackgroundColor)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .cmuxFont(size: 10, weight: .medium)
                .foregroundColor(.secondary)
            TextField(
                String(localized: "sessionIndex.allSessions.searchPlaceholder",
                       defaultValue: "Search sessions…"),
                text: $searchText
            )
            .textFieldStyle(.plain)
            .cmuxFont(size: 12)
            .focused($searchFieldFocused)
            .onSubmit { onPeekTopResult() }
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                onResumeTopResult()
                return .handled
            }
            .onKeyPress(.escape) {
                guard !searchText.isEmpty else { return .ignored }
                searchText = ""
                return .handled
            }
            .accessibilityIdentifier("VaultAllSessionsSearchField")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .cmuxFont(size: 10)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "sessionIndex.allSessions.clearSearch",
                                                defaultValue: "Clear search")))
            }
        }
        // Same control metrics as the grouping pills so the field's box
        // aligns with row-one chrome instead of introducing its own padding.
        .padding(.horizontal, RightSidebarChromeMetrics.controlHorizontalPadding)
        .frame(height: RightSidebarChromeMetrics.controlHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.controlCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .titlebarInteractiveControl()
    }

    private var sortMenu: some View {
        Menu {
            Picker(
                String(localized: "sessionIndex.allSessions.sortBy", defaultValue: "Sort by"),
                selection: $store.recencySort
            ) {
                ForEach(VaultSessionSort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .cmuxFont(size: 10, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "sessionIndex.allSessions.sortTooltip", defaultValue: "Sort sessions"))
        .accessibilityIdentifier("VaultAllSessionsSortMenu")
        .titlebarInteractiveControl()
    }

    private var filterMenu: some View {
        Menu {
            Picker(
                String(localized: "sessionIndex.filter.agent", defaultValue: "Agent"),
                selection: $store.recencyFilter.agentID
            ) {
                Text(String(localized: "sessionIndex.filter.agent.all", defaultValue: "All agents"))
                    .tag(String?.none)
                ForEach(agentOptions, id: \.id) { option in
                    Text(option.label).tag(String?.some(option.id))
                }
            }
            .pickerStyle(.inline)
            Picker(
                String(localized: "sessionIndex.filter.status", defaultValue: "Status"),
                selection: $store.recencyFilter.liveness
            ) {
                ForEach(VaultSessionFilter.Liveness.allCases) { liveness in
                    Text(liveness.label).tag(liveness)
                }
            }
            .pickerStyle(.inline)
            Picker(
                String(localized: "sessionIndex.filter.folder", defaultValue: "Folder"),
                selection: $store.recencyFilter.folder
            ) {
                Text(String(localized: "sessionIndex.filter.folder.all", defaultValue: "All folders"))
                    .tag(String?.none)
                ForEach(folderOptions, id: \.path) { option in
                    Text(option.label).tag(String?.some(option.path))
                }
            }
            .pickerStyle(.inline)
            Picker(
                String(localized: "sessionIndex.filter.date", defaultValue: "Date"),
                selection: $store.recencyFilter.datePreset
            ) {
                ForEach(VaultSessionFilter.DatePreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.inline)
            if store.recencyFilter.isActive {
                Divider()
                Button {
                    store.recencyFilter = VaultSessionFilter()
                } label: {
                    Text(String(localized: "sessionIndex.filter.reset", defaultValue: "Reset Filters"))
                }
            }
        } label: {
            Image(systemName: store.recencyFilter.isActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .cmuxFont(size: 10, weight: .medium)
                .foregroundColor(store.recencyFilter.isActive ? .accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "sessionIndex.allSessions.filterTooltip", defaultValue: "Filter sessions"))
        .accessibilityIdentifier("VaultAllSessionsFilterMenu")
        .titlebarInteractiveControl()
    }

    /// Distinct agents present in the loaded index, in recency order (the
    /// entries array is already sorted by last activity).
    private var agentOptions: [(id: String, label: String)] {
        var seen: Set<String> = []
        var options: [(id: String, label: String)] = []
        for entry in store.entries where seen.insert(entry.agent.rawValue).inserted {
            options.append((id: entry.agent.rawValue, label: entry.agent.displayName))
        }
        return options
    }

    /// Distinct folders present in the loaded index, in recency order.
    private var folderOptions: [(path: String, label: String)] {
        var seen: Set<String> = []
        var options: [(path: String, label: String)] = []
        for entry in store.entries {
            guard let cwd = entry.cwd, !cwd.isEmpty, seen.insert(cwd).inserted else { continue }
            options.append((path: cwd, label: entry.cwdBasename ?? cwd))
        }
        return options
    }
}
