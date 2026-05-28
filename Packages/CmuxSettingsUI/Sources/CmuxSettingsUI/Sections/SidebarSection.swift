import AppKit
import CmuxSettings
import SwiftUI

/// **Sidebar** section rendered as a stack of `SettingsCard`s for
/// layout, workspace row details, appearance, and custom colors.
@MainActor
public struct SidebarSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader("Sidebar Layout")
            SettingsCard {
                toggleRow("Hide All Workspace Details",
                    subtitle: "Show only the workspace title; collapse PR, branch, ports, log, progress.",
                    json: "sidebar.hideAllDetails", key: catalog.sidebar.hideAllDetails)
                SettingsCardDivider()
                toggleRow("Wrap Workspace Titles", subtitle: nil,
                    json: "sidebar.wrapWorkspaceTitles", key: catalog.sidebar.wrapWorkspaceTitles)
                SettingsCardDivider()
                toggleRow("Show Workspace Description", subtitle: nil,
                    json: "sidebar.showWorkspaceDescription", key: catalog.sidebar.showWorkspaceDescription)
                SettingsCardDivider()
                pickerRow("Branch + Directory Layout",
                    json: "sidebar.branchLayout",
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.branchLayout),
                    cases: SidebarBranchLayout.allCases,
                    label: { layout in layout == .inline ? "Inline" : "Stacked" }
                )
                SettingsCardDivider()
                toggleRow("Stack Branch and Directory", subtitle: nil,
                    json: "sidebar.stackBranchDirectory", key: catalog.sidebar.stackBranchDirectory)
                SettingsCardDivider()
                toggleRow("Truncate Path From Start",
                    subtitle: "Show only the deepest directory segment in the cwd display.",
                    json: "sidebar.pathLastSegmentOnly", key: catalog.sidebar.pathLastSegmentOnly)
            }

            SettingsSectionHeader("Workspace Row Details")
            SettingsCard {
                toggleRow("Show Branch and Directory", subtitle: nil,
                    json: "sidebar.showBranchDirectory", key: catalog.sidebar.showBranchDirectory)
                SettingsCardDivider()
                toggleRow("Show Pull Requests", subtitle: nil,
                    json: "sidebar.showPullRequests", key: catalog.sidebar.showPullRequests)
                SettingsCardDivider()
                toggleRow("Watch Git Status", subtitle: nil,
                    json: "sidebar.watchGitStatus", key: catalog.sidebar.watchGitStatus)
                SettingsCardDivider()
                toggleRow("Make PRs Clickable", subtitle: nil,
                    json: "sidebar.makePullRequestsClickable", key: catalog.sidebar.makePullRequestsClickable)
                SettingsCardDivider()
                toggleRow("Open PR Links in cmux Browser", subtitle: nil,
                    json: "sidebar.openPullRequestLinksInCmuxBrowser", key: catalog.sidebar.openPullRequestLinksInCmuxBrowser)
                SettingsCardDivider()
                toggleRow("Open Port Links in cmux Browser", subtitle: nil,
                    json: "sidebar.openPortLinksInCmuxBrowser", key: catalog.sidebar.openPortLinksInCmuxBrowser)
                SettingsCardDivider()
                toggleRow("Show SSH Host", subtitle: nil,
                    json: "sidebar.showSSH", key: catalog.sidebar.showSSH)
                SettingsCardDivider()
                toggleRow("Show Listening Ports", subtitle: nil,
                    json: "sidebar.showPorts", key: catalog.sidebar.showPorts)
                SettingsCardDivider()
                toggleRow("Show Latest Log", subtitle: nil,
                    json: "sidebar.showLog", key: catalog.sidebar.showLog)
                SettingsCardDivider()
                toggleRow("Show Progress", subtitle: nil,
                    json: "sidebar.showProgress", key: catalog.sidebar.showProgress)
                SettingsCardDivider()
                toggleRow("Show Custom Metadata", subtitle: nil,
                    json: "sidebar.showCustomMetadata", key: catalog.sidebar.showCustomMetadata)
                SettingsCardDivider()
                toggleRow("Show Notification Message", subtitle: nil,
                    json: "sidebar.showNotificationMessage", key: catalog.sidebar.showNotificationMessage)
            }

            SettingsSectionHeader("Sidebar Appearance")
            SettingsCard {
                toggleRow("Match Terminal Background", subtitle: nil,
                    json: "sidebarAppearance.matchTerminalBackground",
                    key: catalog.sidebarAppearance.matchTerminalBackground)
                SettingsCardDivider()
                pickerRow("Preset",
                    json: "sidebarAppearance.preset",
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.preset),
                    cases: SidebarPresetOption.allCases,
                    label: presetLabel
                )
                SettingsCardDivider()
                pickerRow("Material",
                    json: "sidebarAppearance.material",
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.material),
                    cases: SidebarMaterialOption.allCases,
                    label: materialLabel
                )
                SettingsCardDivider()
                pickerRow("Blend Mode",
                    json: "sidebarAppearance.blendMode",
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.blendMode),
                    cases: SidebarBlendModeOption.allCases,
                    label: { $0 == .behindWindow ? "Behind Window" : "Within Window" }
                )
                SettingsCardDivider()
                pickerRow("State",
                    json: "sidebarAppearance.state",
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.state),
                    cases: SidebarStateOption.allCases,
                    label: stateLabel
                )
                SettingsCardDivider()
                textRow("Tint Color (#RRGGBB)", subtitle: nil,
                    placeholder: "#101010",
                    json: "sidebarAppearance.tintColor",
                    key: catalog.sidebarAppearance.tintColorHex)
                SettingsCardDivider()
                textRow("Light-mode Tint", subtitle: nil,
                    placeholder: "(default)",
                    json: "sidebarAppearance.lightModeTintColor",
                    key: catalog.sidebarAppearance.lightModeTintColorHex)
                SettingsCardDivider()
                textRow("Dark-mode Tint", subtitle: nil,
                    placeholder: "(default)",
                    json: "sidebarAppearance.darkModeTintColor",
                    key: catalog.sidebarAppearance.darkModeTintColorHex)
                SettingsCardDivider()
                sliderRow("Tint Opacity",
                    json: "sidebarAppearance.tintOpacity",
                    key: catalog.sidebarAppearance.tintOpacity, in: 0...1,
                    format: { String(format: "%.0f%%", $0 * 100) })
                SettingsCardDivider()
                sliderRow("Blur Opacity",
                    json: "sidebarAppearance.blurOpacity",
                    key: catalog.sidebarAppearance.blurOpacity, in: 0...1,
                    format: { String(format: "%.0f%%", $0 * 100) })
                SettingsCardDivider()
                sliderRow("Corner Radius",
                    json: "sidebarAppearance.cornerRadius",
                    key: catalog.sidebarAppearance.cornerRadius, in: 0...20,
                    format: { String(format: "%.0f pt", $0) })
            }

            SettingsSectionHeader("Custom Colors")
            SettingsCard {
                textRow("Selection Color (#RRGGBB)", subtitle: nil,
                    placeholder: "(default)",
                    json: "sidebar.selectionColor", key: catalog.sidebar.selectionColorHex)
                SettingsCardDivider()
                textRow("Notification Badge Color (#RRGGBB)", subtitle: nil,
                    placeholder: "(default)",
                    json: "sidebar.notificationBadgeColor", key: catalog.sidebar.notificationBadgeColorHex)
                SettingsCardDivider()
                textRow("Active Tab Indicator Style", subtitle: nil,
                    placeholder: "default | underline | dot | none",
                    json: "sidebar.activeTabIndicatorStyle", key: catalog.sidebar.activeTabIndicatorStyle)
            }
        }
    }

    @ViewBuilder
    private func toggleRow(_ title: String, subtitle: String?, json: String, key: DefaultsKey<Bool>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle) {
            Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func textRow(_ title: String, subtitle: String?, placeholder: String, json: String, key: DefaultsKey<String>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle, controlWidth: 200) {
            TextField(placeholder, text: Binding(get: { model.current }, set: { model.set($0) }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func pickerRow<Value: SettingCodable & Hashable & CaseIterable>(
        _ title: String,
        json: String,
        model: DefaultsValueModel<Value>,
        cases: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        SettingsCardRow(configurationReview: .json(json), title, controlWidth: 200) {
            Picker("", selection: Binding(get: { model.current }, set: { model.set($0) })) {
                ForEach(cases, id: \.self) { value in Text(label(value)).tag(value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private func sliderRow(_ title: String, json: String, key: DefaultsKey<Double>, in range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, controlWidth: 220) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { model.current }, set: { model.set($0) }), in: range)
                Text(format(model.current))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }

    private func presetLabel(_ preset: SidebarPresetOption) -> String {
        switch preset {
        case .nativeSidebar: return "Native sidebar"
        case .nativeTitlebar: return "Native titlebar"
        case .translucent: return "Translucent"
        case .opaqueDark: return "Opaque dark"
        case .opaqueLight: return "Opaque light"
        case .custom: return "Custom"
        }
    }

    private func materialLabel(_ material: SidebarMaterialOption) -> String {
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

    private func stateLabel(_ state: SidebarStateOption) -> String {
        switch state {
        case .followWindow: return "Follow Window"
        case .active: return "Always Active"
        case .inactive: return "Always Inactive"
        }
    }
}
