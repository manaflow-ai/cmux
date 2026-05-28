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
        .onReceive(NotificationCenter.default.publisher(for: Self.navigationRequestName)) { notification in
            applyNavigationRequest(notification)
        }
    }

    /// Notification name used by the host app to deeplink into a
    /// specific settings section. Compatible with the legacy
    /// `SettingsNavigationRequest.notificationName` in
    /// `Sources/SettingsNavigation.swift` so existing call sites keep
    /// working when the Settings window swaps over to this UI.
    static let navigationRequestName = Notification.Name("cmux.settings.navigate")

    private func applyNavigationRequest(_ notification: Notification) {
        guard
            let rawValue = notification.userInfo?["target"] as? String,
            let target = SettingsSectionID(rawValue: rawValue)
        else { return }
        if selection != target {
            selection = target
        }
        // Anchor + highlight aren't implemented in the package's
        // split-view layout (each section is its own pane, so there's
        // no cross-section scroll-to). External callers that depended
        // on the highlight glow won't see one; the deeplink still
        // routes the user to the correct pane.
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
            AppSection(
                defaultsStore: defaultsStore,
                catalog: catalog,
                hostActions: runtime.hostActions
            )
        case .automation:
            AutomationSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog
            )
        case .account:
            AccountSection(
                defaultsStore: defaultsStore,
                catalog: catalog,
                accountFlow: runtime.accountFlow
            )
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
            BrowserSection(
                defaultsStore: defaultsStore,
                catalog: catalog,
                hostActions: runtime.hostActions
            )
        case .browserImport:
            BrowserImportSection(
                defaultsStore: defaultsStore,
                catalog: catalog,
                hostActions: runtime.hostActions
            )
        case .globalHotkey:
            GlobalHotkeySection(defaultsStore: defaultsStore, catalog: catalog)
        case .keyboardShortcuts:
            KeyboardShortcutsSection(
                jsonStore: jsonStore,
                catalog: catalog,
                errorLog: runtime.errorLog
            )
        case .workspaceColors:
            WorkspaceColorsSection(
                defaultsStore: defaultsStore,
                jsonStore: jsonStore,
                catalog: catalog,
                errorLog: runtime.errorLog
            )
        case .settingsJSON:
            SettingsJSONSection(jsonStore: jsonStore, hostActions: runtime.hostActions)
        case .reset:
            ResetSection(defaultsStore: defaultsStore, jsonStore: jsonStore, catalog: catalog)
        }
    }
}
