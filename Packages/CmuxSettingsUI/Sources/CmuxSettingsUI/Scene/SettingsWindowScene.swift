import CmuxSettings
import SwiftUI

/// The settings window SwiftUI `Scene`.
///
/// Composes a single tall `ScrollView` of stacked sections — the
/// legacy in-app layout — with a left sidebar that scrolls to a
/// section's anchor on click. This mirrors what cmux's settings
/// window has historically looked like; using a `NavigationSplitView`
/// with one-pane-at-a-time selection was a previous (now reverted)
/// architecture choice.
@MainActor
public struct SettingsWindowScene: Scene {
    private let runtime: SettingsRuntime

    public init(runtime: SettingsRuntime) {
        self.runtime = runtime
    }

    public var body: some Scene {
        Window("Settings", id: "cmux.settings") {
            SettingsWindowRoot(runtime: runtime)
                .settingsRuntime(runtime)
        }
        .windowResizability(.contentSize)
    }
}

/// Root view of the settings window. Owns the search query, the
/// scroll proxy, and the section anchors. Renders sidebar + tall
/// scrolling content side-by-side.
@MainActor
public struct SettingsWindowRoot: View {
    let runtime: SettingsRuntime

    public init(runtime: SettingsRuntime) {
        self.runtime = runtime
    }

    @State private var searchText: String = ""
    @State private var selection: SettingsSectionID? = .account

    private var defaultsStore: UserDefaultsSettingsStore { runtime.userDefaultsStore }
    private var jsonStore: JSONConfigStore { runtime.jsonStore }
    private var catalog: SettingCatalog { runtime.catalog }
    private var hostActions: SettingsHostActions? { runtime.hostActions }
    private var accountFlow: AccountFlow? { runtime.accountFlow }

    private var searchIndex: SettingsSearchIndex {
        SettingsSearchIndex(catalog: catalog)
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailScroll
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 920, minHeight: 600)
        .settingsErrorAlert(log: runtime.errorLog)
        .onReceive(NotificationCenter.default.publisher(for: Self.navigationRequestName)) { notification in
            applyNavigationRequest(notification)
        }
    }

    public static let navigationRequestName = Notification.Name("cmux.settings.navigate")

    private func applyNavigationRequest(_ notification: Notification) {
        guard
            let rawValue = notification.userInfo?["target"] as? String,
            let target = SettingsSectionID(rawValue: rawValue)
        else { return }
        if selection != target { selection = target }
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selection) {
            if searchText.isEmpty {
                ForEach(SettingsSectionID.allCases) { section in
                    SettingsSidebarEntryRow(title: section.title, symbolName: section.symbolName, subtitle: nil)
                        .tag(section)
                }
            } else {
                let matches = searchMatches
                if !matches.sections.isEmpty {
                    ForEach(matches.sections) { section in
                        SettingsSidebarEntryRow(title: section.title, symbolName: section.symbolName, subtitle: nil)
                            .tag(section)
                    }
                }
                if !matches.settings.isEmpty {
                    ForEach(matches.settings, id: \.self) { entry in
                        SettingsSidebarEntryRow(title: entry.title, symbolName: entry.section.symbolName, subtitle: entry.section.title)
                            .tag(entry.section)
                    }
                }
                if matches.sections.isEmpty && matches.settings.isEmpty {
                    Text(String(localized: "settings.search.noResults", defaultValue: "No Results"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
        .searchable(text: $searchText, placement: .sidebar, prompt: Text(String(localized: "settings.search.prompt", defaultValue: "Search")))
        .navigationSplitViewColumnWidth(210)
    }

    /// Live search results when the user has typed a query in the
    /// sidebar search field.
    private var searchMatches: (sections: [SettingsSectionID], settings: [CuratedSettingEntry]) {
        let tokens = searchText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { $0.isWhitespace }
            .map(String.init)
        guard !tokens.isEmpty else { return ([], []) }

        let matchingSections = SettingsSectionID.allCases.filter { section in
            let haystack = "\(section.title) \(section.searchKeywords)"
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return tokens.allSatisfy { haystack.contains($0) }
        }
        let matchingSettings: [CuratedSettingEntry] = [CuratedSettingEntry].cmuxDefault.filter { entry in
            let haystack = "\(entry.title) \(entry.synonyms)"
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return tokens.allSatisfy { haystack.contains($0) }
        }
        return (matchingSections, matchingSettings)
    }

    @ViewBuilder
    private var detailScroll: some View {
        GeometryReader { _ in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionStack
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .padding(.top, 20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onChange(of: selection) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(anchorID(for: newValue), anchor: .top)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sectionStack: some View {
        // Order matches the legacy in-app SettingsView scroll order:
        // Account, App, Terminal, Sidebar, Beta Features, Automation,
        // Browser (with embedded Import), Global Hotkey, Keyboard
        // Shortcuts, Workspace Colors, cmux.json, Reset.
        AccountSection(
            defaultsStore: defaultsStore,
            catalog: catalog,
            accountFlow: accountFlow
        )
        .id(anchorID(for: .account))

        AppSection(
            defaultsStore: defaultsStore,
            catalog: catalog,
            hostActions: hostActions
        )
        .id(anchorID(for: .app))

        TerminalSection(
            defaultsStore: defaultsStore,
            jsonStore: jsonStore,
            catalog: catalog
        )
        .id(anchorID(for: .terminal))

        SidebarSection(defaultsStore: defaultsStore, catalog: catalog)
            .id(anchorID(for: .sidebarAppearance))

        BetaFeaturesSection(defaultsStore: defaultsStore, catalog: catalog)
            .id(anchorID(for: .betaFeatures))

        AutomationSection(
            defaultsStore: defaultsStore,
            jsonStore: jsonStore,
            catalog: catalog
        )
        .id(anchorID(for: .automation))

        BrowserSection(
            defaultsStore: defaultsStore,
            catalog: catalog,
            hostActions: hostActions,
            importAnchorID: anchorID(for: .browserImport)
        )
        .id(anchorID(for: .browser))

        GlobalHotkeySection(defaultsStore: defaultsStore, catalog: catalog)
            .id(anchorID(for: .globalHotkey))

        KeyboardShortcutsSection(
            jsonStore: jsonStore,
            catalog: catalog,
            errorLog: runtime.errorLog,
            hostActions: hostActions
        )
        .id(anchorID(for: .keyboardShortcuts))

        WorkspaceColorsSection(
            defaultsStore: defaultsStore,
            jsonStore: jsonStore,
            catalog: catalog,
            errorLog: runtime.errorLog
        )
        .id(anchorID(for: .workspaceColors))

        SettingsJSONSection(jsonStore: jsonStore, hostActions: hostActions)
            .id(anchorID(for: .settingsJSON))

        ResetSection(
            defaultsStore: defaultsStore,
            jsonStore: jsonStore,
            catalog: catalog
        )
        .id(anchorID(for: .reset))
    }

    private func anchorID(for section: SettingsSectionID) -> String {
        "section:\(section.rawValue)"
    }
}
