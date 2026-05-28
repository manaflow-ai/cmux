import CmuxSettings
import SwiftUI

/// The settings window SwiftUI `Scene`.
///
/// Compose this in the cmux app's `App.body`:
///
/// ```swift
/// var body: some Scene {
///     WindowGroup { MainWindowBootstrapView() }
///     SettingsWindowScene(
///         defaultsStore: AppSettings.defaultsStore,
///         jsonStore: AppSettings.jsonStore,
///         catalog: AppSettings.catalog
///     )
/// }
/// ```
///
/// Renders a `NavigationSplitView` with a searchable sidebar of
/// ``SettingsSectionID`` cases on the left and the selected section's
/// view on the right. Sections that have been migrated render their
/// real view; the rest render a ``PlaceholderSection`` until they are
/// brought across from `Sources/cmuxApp.swift`.
@MainActor
public struct SettingsWindowScene: Scene {
    private let defaultsStore: UserDefaultsSettingsStore
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog
    ) {
        self.defaultsStore = defaultsStore
        self.jsonStore = jsonStore
        self.catalog = catalog
    }

    public var body: some Scene {
        Window("Settings", id: "cmux.settings") {
            SettingsWindowRoot(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog
            )
        }
        .windowResizability(.contentSize)
    }
}

/// Root view of the settings window. Owns the selection state, the
/// search query, and the `NavigationSplitView` chrome.
@MainActor
struct SettingsWindowRoot: View {
    let defaultsStore: UserDefaultsSettingsStore
    let jsonStore: JSONConfigStore
    let catalog: SettingCatalog

    @State private var selection: SettingsSectionID = .account
    @State private var searchText: String = ""

    private var searchIndex: SettingsSearchIndex {
        SettingsSearchIndex(catalog: catalog)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 540)
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(searchIndex.match(searchText)) { entry in
                sidebarRow(entry)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Settings")
        .searchable(text: $searchText, placement: .sidebar, prompt: Text("Search"))
        .frame(minWidth: 200)
    }

    @ViewBuilder
    private func sidebarRow(_ entry: SettingsSearchIndex.Entry) -> some View {
        switch entry.kind {
        case .section:
            if let sectionID = SettingsSectionID(rawValue: entry.id.replacingOccurrences(of: "section:", with: "")) {
                Label(entry.title, systemImage: entry.symbolName).tag(sectionID)
            }
        case .setting(let parent):
            Button {
                selection = parent
            } label: {
                Label(entry.title, systemImage: entry.symbolName)
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .app:
            AppSection(defaultsStore: defaultsStore, catalog: catalog)
        case .automation:
            AutomationSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog
            )
        case .account:
            AccountSection()
        case .terminal:
            TerminalSection(defaultsStore: defaultsStore, catalog: catalog)
        case .sidebarAppearance:
            SidebarSection(defaultsStore: defaultsStore, catalog: catalog)
        case .betaFeatures:
            BetaFeaturesSection(defaultsStore: defaultsStore, catalog: catalog)
        case .browser:
            BrowserSection(defaultsStore: defaultsStore, catalog: catalog)
        case .browserImport:
            BrowserImportSection(defaultsStore: defaultsStore, catalog: catalog)
        case .globalHotkey:
            GlobalHotkeySection()
        case .keyboardShortcuts:
            KeyboardShortcutsSection(jsonStore: jsonStore, catalog: catalog)
        case .workspaceColors:
            WorkspaceColorsSection(defaultsStore: defaultsStore, catalog: catalog)
        case .settingsJSON:
            SettingsJSONSection(jsonStore: jsonStore)
        case .reset:
            ResetSection(defaultsStore: defaultsStore, jsonStore: jsonStore, catalog: catalog)
        }
    }
}
