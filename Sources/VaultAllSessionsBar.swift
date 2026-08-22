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
        HStack(spacing: 5) {
            searchField
            if showsSortAndFilter {
                Divider()
                    .frame(height: 16)
                    .opacity(0.45)
                sortMenu
                filterMenu
            }
        }
        // Same margins as the Vault popover's standardized search row.
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .rightSidebarChromeBottomBorder(backgroundColor: chromeBackgroundColor)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .cmuxFont(size: 11, weight: .medium)
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
                        .cmuxFont(size: 11)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "sessionIndex.allSessions.clearSearch",
                                                defaultValue: "Clear search")))
            }
        }
        // The one standardized Vault search-field style, shared with
        // SectionPopoverView's "Search Vault" row.
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
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
            VaultToolbarIcon(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .contentShape(Rectangle())
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
                ForEach(store.agentFilterOptions) { option in
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
                ForEach(store.folderFilterOptions) { option in
                    Text(option.label).tag(String?.some(option.id))
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
            VaultToolbarIcon(
                systemName: store.recencyFilter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle",
                isActive: store.recencyFilter.isActive
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .contentShape(Rectangle())
        .help(String(localized: "sessionIndex.allSessions.filterTooltip", defaultValue: "Filter sessions"))
        .accessibilityIdentifier("VaultAllSessionsFilterMenu")
        .titlebarInteractiveControl()
    }

}

/// Consistent 20-point utility target for search-row menus. The quiet resting
/// state keeps the field primary; hover and active states make the affordance
/// legible without adding another pill to the toolbar.
private struct VaultToolbarIcon: View {
    let systemName: String
    var isActive = false
    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.monochrome)
            .cmuxFont(size: RightSidebarChromeMetrics.headerIconSize, weight: .regular)
            .foregroundStyle(
                isActive
                    ? Color.accentColor
                    : HeaderChromeIconStyle.foregroundColor.opacity(
                        isHovered
                            ? HeaderChromeIconStyle.hoveredOpacity
                            : HeaderChromeIconStyle.opacity
                    )
            )
            .frame(
                width: RightSidebarChromeMetrics.headerControlSize,
                height: RightSidebarChromeMetrics.headerControlSize
            )
            .background {
                if isActive || isHovered {
                    RoundedRectangle(
                        cornerRadius: RightSidebarChromeMetrics.headerControlCornerRadius,
                        style: .continuous
                    )
                    .fill(
                        isActive
                            ? Color.accentColor.opacity(0.12)
                            : Color.primary.opacity(0.07)
                    )
                }
            }
            .contentShape(
                RoundedRectangle(
                    cornerRadius: RightSidebarChromeMetrics.headerControlCornerRadius,
                    style: .continuous
                )
            )
            .onHover { isHovered = $0 }
    }
}
