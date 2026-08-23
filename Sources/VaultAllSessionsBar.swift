import SwiftUI

/// Chrome row shown for every Vault grouping: session search field
/// plus sort and filter menus. Mounted directly by `SessionIndexView` above
/// the table boundary, mirroring the existing control bar (safe to observe
/// the store here — never inside table rows).
struct VaultAllSessionsBar: View {
    @ObservedObject var store: SessionIndexStore
    /// Sort and filters act on the recency ("All") sections; other groupings
    /// keep only the search field.
    let showsSortAndFilter: Bool
    @Binding var searchText: String
    /// Enter — peek the top search result.
    let onPeekTopResult: () -> Void
    /// Cmd+Enter — resume the top search result.
    let onResumeTopResult: () -> Void

    @FocusState private var searchFieldFocused: Bool
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    private var searchFieldHeight: CGFloat {
        _ = globalFontPercent
        // A native NSSearchField sits at roughly 22 points on macOS. Keep
        // that comfortable baseline while allowing the app-wide text scale
        // to grow the control instead of clipping its editor.
        return max(22, RightSidebarChromeMetrics.controlHeight + 2)
    }

    private var searchBarHeight: CGFloat {
        max(RightSidebarChromeMetrics.secondaryBarHeight, searchFieldHeight + 6)
    }

    var body: some View {
        HStack(spacing: RightSidebarChromeMetrics.headerControlSpacing) {
            searchField
            if showsSortAndFilter {
                sortMenu
                filterMenu
            }
        }
        // Keep the same 28-point rhythm and 4/6-point outer insets as the
        // mode bar, but let this toolbar flow into the session list without a
        // second separator line. The field itself is two points taller than
        // the compact icon controls, so use three-point vertical insets here.
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .frame(height: searchBarHeight)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .cmuxFont(size: 12, weight: .regular)
                .foregroundColor(.secondary)
            TextField(
                String(localized: "sessionIndex.allSessions.searchPlaceholder",
                       defaultValue: "Search sessions…"),
                text: $searchText
            )
            .textFieldStyle(.plain)
            .cmuxFont(size: 13)
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
                        .cmuxFont(size: 12)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "sessionIndex.allSessions.clearSearch",
                                                defaultValue: "Clear search")))
            }
        }
        // A plain editor inside one low-contrast, borderless control fill
        // keeps the behavior of a normal macOS search field without adding a
        // second outline to the chrome.
        .padding(.horizontal, 9)
        .frame(height: searchFieldHeight)
        .background(
            RoundedRectangle(
                cornerRadius: 7,
                style: .continuous
            )
                .fill(Color.primary.opacity(0.06))
        )
        // The field owns the flexible width; the utility controls keep their
        // standard 20-point targets at the trailing edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
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
