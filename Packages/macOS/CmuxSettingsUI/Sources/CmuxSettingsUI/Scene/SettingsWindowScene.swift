import AppKit
import CmuxSettings
import SwiftUI

/// Where the Settings root is hosted. The window keeps AppKit's split view
/// (full-height sidebar, toolbar toggle); a workspace pane draws a flat
/// two-column layout in the pane's own chrome, with no window furniture.
public enum SettingsRootPresentation: Sendable {
    case window
    case pane
}

/// Settings sidebar and its selected category page, hosted by the app's
/// AppKit-owned Settings window or embedded in a workspace pane. Search
/// results and external navigation share one path that selects a page
/// before scrolling to its row.
@MainActor
public struct SettingsWindowRoot: View {
    let runtime: SettingsRuntime
    private let searchIndex: SettingsSearchIndex
    private let initialSection: SettingsSectionID?
    private let presentation: SettingsRootPresentation

    static let selectedSectionDefaultsKey = "selectedSettingsSection"
    static let cloudMachinesBetaDefaultsKey = "cloud.beta.machines.enabled"

    /// Creates a settings window's content.
    ///
    /// - Parameters:
    ///   - runtime: Catalog, stores, and host actions shared by every page.
    ///   - initialSection: Category rendered in the first layout pass. `nil`
    ///     restores the category saved in the view's default AppStorage.
    ///   - presentation: Window split view, or the flat pane layout.
    public init(runtime: SettingsRuntime, initialSection: SettingsSectionID? = nil, presentation: SettingsRootPresentation = .window) {
        self.runtime = runtime
        self.searchIndex = runtime.searchIndex
        self.initialSection = initialSection
        self.presentation = presentation
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
        hostLayout
            .environment(\.settingsSearchIndex, searchIndex)
            .environment(\.settingsSearchHighlightState, searchHighlight)
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

    @ViewBuilder
    private var hostLayout: some View {
        switch presentation {
        case .window:
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } detail: {
                detailPage
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 820, minHeight: 540)
        case .pane:
            HStack(spacing: 0) {
                paneSidebar
                    .frame(width: 208)
                Divider()
                detailPage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The embedded sidebar: a compact search field over plain category rows on
    /// the same background as the page, separated only by a hairline seam.
    private var paneSidebar: some View {
        VStack(spacing: 0) {
            SettingsPaneSearchField(text: $searchText)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
            ScrollView {
                let matches = sidebarEntries(matching: searchText).filter { isEntryVisible($0) }
                LazyVStack(alignment: .leading, spacing: 1) {
                    if matches.isEmpty {
                        Text(String(localized: "settings.search.noResults", defaultValue: "No Results"))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    ForEach(matches) { entry in
                        SettingsPaneSidebarRow(
                            title: entry.title,
                            symbolName: entry.symbolName,
                            subtitle: subtitle(for: entry),
                            isSelected: entry.id == selectedSidebarEntryID
                        ) {
                            selectSidebarEntry(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
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

/// One category row in the embedded sidebar: selection pill in the accent
/// tint, a quiet hover wash, and the same glyph column as the window sidebar.
private struct SettingsPaneSidebarRow: View {
    let title: String
    let symbolName: String
    let subtitle: String?
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, subtitle == nil ? 6 : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The embedded sidebar's search field: the real AppKit search field, so it
/// gets the native rounded bezel, magnifier, clear button, and focus ring
/// instead of a hand-drawn capsule.
private struct SettingsPaneSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "settings.search.prompt", defaultValue: "Search")
        field.controlSize = .regular
        field.font = .systemFont(ofSize: 13)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            if text != field.stringValue { text = field.stringValue }
        }
    }
}
