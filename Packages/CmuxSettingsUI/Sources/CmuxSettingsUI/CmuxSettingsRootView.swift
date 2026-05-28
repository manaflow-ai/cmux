import SwiftUI

public struct CmuxSettingsRootView<Detail: View>: View {
    @Binding private var columnVisibility: NavigationSplitViewVisibility
    @Binding private var searchText: String

    private let minimumSize: CGSize
    private let keyboardShortcutActionAliases: () -> String
    private let consumePendingNavigationTarget: () -> SettingsNavigationTarget?
    private let detail: () -> Detail

    @SceneStorage("selectedSettingsSection") private var selectedSectionRaw = SettingsNavigationTarget.account.rawValue
    @SceneStorage("selectedSettingsSidebarEntry") private var selectedSidebarEntryID = SettingsSearchIndex.defaultSelectionID

    public init(
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        searchText: Binding<String>,
        minimumSize: CGSize,
        keyboardShortcutActionAliases: @escaping () -> String = { "" },
        consumePendingNavigationTarget: @escaping () -> SettingsNavigationTarget? = { nil },
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self._columnVisibility = columnVisibility
        self._searchText = searchText
        self.minimumSize = minimumSize
        self.keyboardShortcutActionAliases = keyboardShortcutActionAliases
        self.consumePendingNavigationTarget = consumePendingNavigationTarget
        self.detail = detail
    }

    private var selectedSection: SettingsNavigationTarget {
        SettingsNavigationTarget(rawValue: selectedSectionRaw) ?? .account
    }

    private var sidebarEntries: [SettingsSearchEntry] {
        SettingsSearchAliasIndex.keyboardShortcutActionAliasesProvider = keyboardShortcutActionAliases
        return SettingsSearchIndex.entries(matching: searchText)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sidebarSelection: Binding<String> {
        Binding(
            get: { selectedSidebarEntryID },
            set: { selectSidebarEntry($0) }
        )
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: sidebarSelection) {
                if sidebarEntries.isEmpty {
                    Text(String(localized: "settings.search.noResults", defaultValue: "No Results"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sidebarEntries) { entry in
                        CmuxSettingsSidebarEntryRow(entry: entry)
                            .tag(entry.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
            .searchable(
                text: $searchText,
                placement: .sidebar,
                prompt: Text(String(localized: "settings.search.prompt", defaultValue: "Search"))
            )
            .navigationSplitViewColumnWidth(210)
        } detail: {
            detail()
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
        .onChange(of: searchText) { newValue in
            guard newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            selectedSidebarEntryID = SettingsSearchIndex.sectionID(for: selectedSection)
        }
        .onAppear {
            if let target = consumePendingNavigationTarget() {
                navigate(to: target, postRequest: true)
            } else {
                navigate(to: selectedSection, postRequest: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsNavigationRequest.notificationName)) { notification in
            guard let target = SettingsNavigationRequest.target(from: notification) else { return }
            let selectedEntry = SettingsSearchIndex.entry(withID: selectedSidebarEntryID)
            let shouldPreserveSearchSelection = isSearching && selectedEntry?.target == target
            navigate(to: target, preferSectionSelection: !shouldPreserveSearchSelection, postRequest: false)
        }
    }

    private func selectSidebarEntry(_ entryID: String) {
        guard let entry = SettingsSearchIndex.entry(withID: entryID) else { return }
        selectedSidebarEntryID = entry.id
        selectedSectionRaw = entry.target.rawValue
        SettingsNavigationRequest.post(entry.target, anchorID: entry.id, highlight: isSearching)
    }

    private func navigate(
        to target: SettingsNavigationTarget,
        preferSectionSelection: Bool = true,
        postRequest: Bool
    ) {
        selectedSectionRaw = target.rawValue
        if preferSectionSelection {
            selectedSidebarEntryID = SettingsSearchIndex.sectionID(for: target)
        }
        if postRequest {
            SettingsNavigationRequest.post(target)
        }
    }
}

private struct CmuxSettingsSidebarEntryRow: View {
    let entry: SettingsSearchEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .lineLimit(1)

                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
