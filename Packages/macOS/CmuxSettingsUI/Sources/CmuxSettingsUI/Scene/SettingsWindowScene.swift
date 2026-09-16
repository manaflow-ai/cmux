import CmuxSettings
import SwiftUI

/// Settings sidebar and its selected category page, hosted by the app's
/// AppKit-owned Settings window. Search results and external navigation
/// share one path that selects a page before scrolling to its row.
@MainActor
public struct SettingsWindowRoot: View {
    let runtime: SettingsRuntime
    private let searchIndex: SettingsSearchIndex
    private let initialSection: SettingsSectionID?

    static let selectedSectionDefaultsKey = "selectedSettingsSection"
    static let cloudMachinesBetaDefaultsKey = "cloud.beta.machines.enabled"

    /// Creates a settings window's content.
    ///
    /// - Parameters:
    ///   - runtime: Catalog, stores, and host actions shared by every page.
    ///   - initialSection: Category rendered in the first layout pass. `nil`
    ///     restores the category saved in the view's default AppStorage.
    public init(runtime: SettingsRuntime, initialSection: SettingsSectionID? = nil) {
        self.runtime = runtime
        self.searchIndex = runtime.searchIndex
        self.initialSection = initialSection
    }

    init(runtime: SettingsRuntime, initialSection: SettingsSectionID, pageDrafts: SettingsPageDrafts) {
        self.init(runtime: runtime, initialSection: initialSection)
        _pageDrafts = State(initialValue: pageDrafts)
    }

    @State var pageDrafts = SettingsPageDrafts()
    @State private var initialNavigationPending = true
    @State private var cloudDisabledByPolicy = ManagedDevicePolicy().isEnforced(.disableCloud)
    @State private var cloudFeatureFlagRevision = 0
    @State private var searchText = ""
    // The page and the highlighted search result are distinct selections:
    // sibling results can navigate to different rows on the same page.
    @AppStorage(SettingsWindowRoot.selectedSectionDefaultsKey)
    private var selectedSectionRaw = SettingsSectionID.account.rawValue
    @AppStorage("selectedSettingsSidebarEntry")
    private var selectedSidebarEntryID = "section:\(SettingsSectionID.account.rawValue)"
    @AppStorage(SettingsWindowRoot.cloudMachinesBetaDefaultsKey)
    private var cloudMachinesBetaEnabled = BetaFeaturesCatalogSection().cloudMachines.defaultValue
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var navigationGeneration = 0
    @State private var pageRevision = 0
    @State private var scrollAnchorID: String?
    @State private var searchHighlight = SettingsSearchHighlightState(anchorID: nil, token: 0, startedAt: nil)

    var defaultsStore: UserDefaultsSettingsStore { runtime.userDefaultsStore }
    var jsonStore: JSONConfigStore { runtime.jsonStore }
    var secretStore: SecretFileStore { runtime.secretStore }
    var catalog: SettingCatalog { runtime.catalog }
    var hostActions: SettingsHostActions { runtime.hostActions }
    var accountFlow: AccountFlow? { runtime.accountFlow }

    var isCloudSectionAvailable: Bool {
        _ = cloudFeatureFlagRevision
        return !cloudDisabledByPolicy && hostActions.isCloudMachinesAvailable && cloudMachinesBetaEnabled
    }

    private var selectedSection: SettingsSectionID {
        let section = initialNavigationPending
            ? initialSection ?? SettingsSectionID(rawValue: selectedSectionRaw) ?? .account
            : SettingsSectionID(rawValue: selectedSectionRaw) ?? .account
        return section == .cloudMachines && !isCloudSectionAvailable ? .account : section
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sidebarSelection: Binding<String> {
        Binding(get: { selectedSidebarEntryID }, set: { selectSidebarEntry($0) })
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detailPage
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.settingsSearchIndex, searchIndex)
        .environment(\.settingsSearchHighlightState, searchHighlight)
        .frame(minWidth: 820, minHeight: 540)
        .settingsErrorAlert(log: runtime.errorLog)
        .onAppear {
            guard initialNavigationPending else { return }
            let section = selectedSection
            let restoredEntry = searchIndex.entries.first { $0.id == selectedSidebarEntryID }
            let anchor = initialSection == nil && restoredEntry.map { parentSection(for: $0) } == section
                ? restoredEntry?.anchorID ?? anchorID(for: section)
                : anchorID(for: section)
            postNavigationRequest(target: section, anchorID: anchor, highlight: false)
        }
        .task {
            let signals = ManagedDevicePolicy.changeSignals()
            cloudDisabledByPolicy = ManagedDevicePolicy().isEnforced(.disableCloud)
            leaveUnavailableCloudPage()
            for await _ in signals {
                cloudDisabledByPolicy = ManagedDevicePolicy().isEnforced(.disableCloud)
                leaveUnavailableCloudPage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.navigationRequestName)) { notification in
            applyNavigationRequest(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.sidebarToggleRequestName)) { _ in
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("cmuxFeatureFlagsDidChange"))) { _ in
            cloudFeatureFlagRevision &+= 1
            leaveUnavailableCloudPage()
        }
        .onChange(of: cloudMachinesBetaEnabled) { _, _ in
            leaveUnavailableCloudPage()
        }
        .onChange(of: searchText) { _, newValue in
            guard newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            selectedSidebarEntryID = anchorID(for: selectedSection)
        }
    }

    public static let navigationRequestName = Notification.Name("cmux.settings.navigate")
    public static let sidebarToggleRequestName = Notification.Name("cmux.settings.toggleSidebar")

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            let matches = sidebarEntries(matching: searchText).filter { isEntryVisible($0) }
            if matches.isEmpty {
                Text(String(localized: "settings.search.noResults", defaultValue: "No Results"))
                    .foregroundStyle(.secondary)
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
        .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
        .searchable(text: $searchText, placement: .sidebar, prompt: Text(String(localized: "settings.search.prompt", defaultValue: "Search")))
        .navigationSplitViewColumnWidth(210)
    }

    func sidebarEntries(matching query: String) -> [SettingsSearchIndex.Entry] {
        searchIndex.match(query)
    }

    private func isEntryVisible(_ entry: SettingsSearchIndex.Entry) -> Bool {
        isCloudSectionAvailable || parentSection(for: entry) != .cloudMachines
    }

    private func subtitle(for entry: SettingsSearchIndex.Entry) -> String? {
        switch entry.kind {
        case .section: return nil
        case .setting(let parent): return parent.title
        }
    }

    private func parentSection(for entry: SettingsSearchIndex.Entry) -> SettingsSectionID {
        switch entry.kind {
        case .section:
            return SettingsSectionID(rawValue: String(entry.id.dropFirst("section:".count))) ?? .account
        case .setting(let parent):
            return parent
        }
    }

    private func selectSidebarEntry(_ entryID: String) {
        guard let entry = searchIndex.entries.first(where: { $0.id == entryID }), isEntryVisible(entry) else { return }
        selectedSidebarEntryID = entry.id
        postNavigationRequest(target: parentSection(for: entry), anchorID: entry.anchorID, highlight: isSearching)
    }

    private func postNavigationRequest(target: SettingsSectionID, anchorID: String, highlight: Bool) {
        NotificationCenter.default.post(
            name: Self.navigationRequestName,
            object: nil,
            userInfo: ["target": target.rawValue, "anchor": anchorID, "highlight": highlight]
        )
    }

    private func applyNavigationRequest(_ notification: Notification) {
        guard let rawValue = notification.userInfo?["target"] as? String,
              let requestedSection = SettingsSectionID(rawValue: rawValue) else { return }
        let target = requestedSection == .cloudMachines && !isCloudSectionAvailable ? .account : requestedSection
        let entry = searchIndex.entries.first { $0.id == selectedSidebarEntryID }
        if !isSearching || entry.map({ parentSection(for: $0) }) != target {
            selectedSidebarEntryID = anchorID(for: target)
        }
        let anchor = target == requestedSection
            ? (notification.userInfo?["anchor"] as? String) ?? anchorID(for: target)
            : anchorID(for: target)
        // Re-selecting a category resets its native scroll view to its
        // natural top. Row navigation alone uses ScrollViewReader.
        if !initialNavigationPending, target == selectedSection, anchor == anchorID(for: target) {
            pageRevision &+= 1
        }
        selectedSectionRaw = target.rawValue
        initialNavigationPending = false
        scrollAnchorID = anchor
        navigationGeneration &+= 1
        let shouldHighlight = (notification.userInfo?["highlight"] as? Bool) ?? false
        searchHighlight = SettingsSearchHighlightState(
            anchorID: shouldHighlight ? anchor : nil,
            token: navigationGeneration,
            startedAt: shouldHighlight ? Date() : nil
        )
    }

    private func leaveUnavailableCloudPage() {
        guard !isCloudSectionAvailable, selectedSectionRaw == SettingsSectionID.cloudMachines.rawValue else { return }
        postNavigationRequest(target: .account, anchorID: anchorID(for: .account), highlight: false)
    }

    private var detailPage: some View {
        let section = selectedSection
        return ScrollViewReader { proxy in
            ScrollView {
                // Eager within one page so all of its search anchors exist.
                VStack(alignment: .leading, spacing: 14) {
                    sectionPage(section)
                }
                .id(anchorID(for: section))
                .padding(20)
                .onAppear { scrollToDestination(on: section, proxy: proxy) }
            }
            .toggleStyle(.switch)
            .onChange(of: navigationGeneration) { _, _ in
                scrollToDestination(on: section, proxy: proxy)
            }
        }
        // A category owns its scroll view and controls. Replacing it resets
        // scroll position and cancels the previous page's observation tasks.
        .id("\(section.rawValue):\(pageRevision)")
    }

    private func scrollToDestination(on section: SettingsSectionID, proxy: ScrollViewProxy) {
        guard section == selectedSection else { return }
        let anchor = scrollAnchorID ?? anchorID(for: section)
        guard anchor != anchorID(for: section) else { return }
        proxy.scrollTo(anchor, anchor: .center)
    }
}
