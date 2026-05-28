import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Sidebar** section (sidebar appearance + workspace
/// row details). The original cmux app interleaves these; the new layout
/// keeps them in the same pane via two `Section`s.
public struct SidebarSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            Section("Layout") {
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.hideAllDetails),
                    title: "Hide all workspace details",
                    subtitle: "Show only the workspace title; collapse PR, branch, ports, log, progress."
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.wrapWorkspaceTitles),
                    title: "Wrap workspace titles"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showWorkspaceDescription),
                    title: "Show workspace description"
                )
                SettingsPickerRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.branchLayout),
                    title: "Branch + directory layout",
                    label: { layout in
                        switch layout {
                        case .inline: return "Inline"
                        case .vertical: return "Stacked"
                        }
                    }
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.stackBranchDirectory),
                    title: "Stack branch and directory on separate lines"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.pathLastSegmentOnly),
                    title: "Truncate path from start",
                    subtitle: "Show only the deepest directory segment in the cwd display."
                )
            }
            Section("Workspace row details") {
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showBranchDirectory),
                    title: "Show branch and directory"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showPullRequests),
                    title: "Show pull requests"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.watchGitStatus),
                    title: "Watch git status"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.makePullRequestsClickable),
                    title: "Make PRs clickable"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.openPullRequestLinksInCmuxBrowser),
                    title: "Open PR links in cmux browser"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.openPortLinksInCmuxBrowser),
                    title: "Open port links in cmux browser"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showSSH),
                    title: "Show SSH host"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showPorts),
                    title: "Show listening ports"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showLog),
                    title: "Show latest log"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showProgress),
                    title: "Show progress"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showCustomMetadata),
                    title: "Show custom metadata"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.showNotificationMessage),
                    title: "Show notification message"
                )
            }
            Section("Appearance") {
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.matchTerminalBackground),
                    title: "Match terminal background"
                )
                SettingsPickerRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.preset),
                    title: "Preset",
                    label: { preset in
                        switch preset {
                        case .nativeSidebar: return "Native sidebar"
                        case .nativeTitlebar: return "Native titlebar"
                        case .translucent: return "Translucent"
                        case .opaqueDark: return "Opaque dark"
                        case .opaqueLight: return "Opaque light"
                        case .custom: return "Custom"
                        }
                    }
                )
                SettingsPickerRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.material),
                    title: "Material",
                    label: { material in
                        switch material {
                        case .sidebar: return "Sidebar"
                        case .hudWindow: return "HUD"
                        case .menu: return "Menu"
                        case .titlebar: return "Titlebar"
                        case .selection: return "Selection"
                        case .popover: return "Popover"
                        case .headerView: return "Header"
                        case .underWindowBackground: return "Under Window Background"
                        case .sheet: return "Sheet"
                        case .windowBackground: return "Window Background"
                        case .fullScreenUI: return "Full Screen UI"
                        case .toolTip: return "Tool Tip"
                        case .contentBackground: return "Content Background"
                        case .underPageBackground: return "Under Page Background"
                        }
                    }
                )
                SettingsPickerRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.blendMode),
                    title: "Blend mode",
                    label: { mode in
                        switch mode {
                        case .behindWindow: return "Behind Window"
                        case .withinWindow: return "Within Window"
                        }
                    }
                )
                SettingsPickerRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.state),
                    title: "State",
                    label: { state in
                        switch state {
                        case .followWindow: return "Follow Window"
                        case .active: return "Always Active"
                        case .inactive: return "Always Inactive"
                        }
                    }
                )
                tintRow(title: "Tint color (#RRGGBB)", key: catalog.sidebarAppearance.tintColorHex)
                tintRow(title: "Light-mode tint", key: catalog.sidebarAppearance.lightModeTintColorHex)
                tintRow(title: "Dark-mode tint", key: catalog.sidebarAppearance.darkModeTintColorHex)
                tintOpacityRow
                blurOpacityRow
                cornerRadiusRow
            }
            Section("Custom Colors") {
                SettingsDefaultsTextFieldRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.selectionColorHex),
                    title: "Selection color (#RRGGBB)",
                    placeholder: "(default)"
                )
                SettingsDefaultsTextFieldRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.notificationBadgeColorHex),
                    title: "Notification badge color (#RRGGBB)",
                    placeholder: "(default)"
                )
                SettingsDefaultsTextFieldRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.activeTabIndicatorStyle),
                    title: "Active tab indicator style",
                    placeholder: "default | underline | dot | none"
                )
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var blurOpacityRow: some View {
        let model = DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.blurOpacity)
        VStack(alignment: .leading) {
            HStack {
                Text("Blur opacity")
                Spacer()
                Text(String(format: "%.0f%%", model.current * 100))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { model.current }, set: { model.set($0) }), in: 0...1)
        }
    }

    @ViewBuilder
    private func tintRow(title: String, key: DefaultsKey<String>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        TextField(title, text: Binding(get: { model.current }, set: { model.set($0) }))
            .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private var tintOpacityRow: some View {
        let model = DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.tintOpacity)
        VStack(alignment: .leading) {
            HStack {
                Text("Tint opacity")
                Spacer()
                Text(String(format: "%.0f%%", model.current * 100))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { model.current }, set: { model.set($0) }), in: 0...1)
        }
    }

    @ViewBuilder
    private var cornerRadiusRow: some View {
        let model = DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.cornerRadius)
        VStack(alignment: .leading) {
            HStack {
                Text("Corner radius")
                Spacer()
                Text(String(format: "%.0f pt", model.current))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { model.current }, set: { model.set($0) }), in: 0...20)
        }
    }
}
