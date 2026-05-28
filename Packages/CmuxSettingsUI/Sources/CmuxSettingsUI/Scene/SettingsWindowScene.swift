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

/// Root view of the settings window. Owns the selection state, the
/// search query, and the `NavigationSplitView` chrome.
///
/// Public so a host app that wants to declare its own outer
/// `Window(...)` scene (to keep its existing window id, default
/// size, command groups, etc.) can host the package's settings UI
/// without taking ``SettingsWindowScene`` wholesale.
@MainActor
public struct SettingsWindowRoot: View {
    let runtime: SettingsRuntime

    public init(runtime: SettingsRuntime) {
        self.runtime = runtime
    }

    @State private var selection: SettingsSectionID = .account
    @State private var searchText: String = ""

    private var defaultsStore: UserDefaultsSettingsStore { runtime.userDefaultsStore }
    private var jsonStore: JSONConfigStore { runtime.jsonStore }
    private var catalog: SettingCatalog { runtime.catalog }

    private var searchIndex: SettingsSearchIndex {
        SettingsSearchIndex(catalog: catalog)
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 540)
        .settingsErrorAlert(log: runtime.errorLog)
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
            AccountSection(defaultsStore: defaultsStore, catalog: catalog)
        case .terminal:
            TerminalSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog
            )
        case .sidebarAppearance:
            SidebarSection(defaultsStore: defaultsStore, catalog: catalog)
        case .betaFeatures:
            BetaFeaturesSection(defaultsStore: defaultsStore, catalog: catalog)
        case .browser:
            BrowserSection(defaultsStore: defaultsStore, catalog: catalog)
        case .browserImport:
            BrowserImportSection(defaultsStore: defaultsStore, catalog: catalog)
        case .globalHotkey:
            GlobalHotkeySection(defaultsStore: defaultsStore, catalog: catalog)
        case .keyboardShortcuts:
            KeyboardShortcutsSection(
                jsonStore: jsonStore,
                catalog: catalog,
                errorLog: runtime.errorLog
            )
        case .workspaceColors:
            WorkspaceColorsSection(defaultsStore: defaultsStore, catalog: catalog)
        case .settingsJSON:
            SettingsJSONSection(jsonStore: jsonStore)
        case .reset:
            ResetSection(defaultsStore: defaultsStore, jsonStore: jsonStore, catalog: catalog)
        }
    }
}
