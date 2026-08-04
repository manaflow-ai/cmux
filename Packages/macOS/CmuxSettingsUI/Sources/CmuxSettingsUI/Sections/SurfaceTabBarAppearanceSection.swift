import AppKit
import CmuxSettings
import SwiftUI

/// Selection-dependent colors and indicator placement for pane surface tabs.
@MainActor
public struct SurfaceTabBarAppearanceSection: View {
    @State private var activeBackground: JSONValueModel<String>
    @State private var activeForeground: JSONValueModel<String>
    @State private var inactiveBackground: JSONValueModel<String>
    @State private var inactiveForeground: JSONValueModel<String>
    @State private var divider: JSONValueModel<String>
    @State private var indicator: JSONValueModel<String>
    @State private var indicatorEdge: JSONValueModel<String>

    public init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog
    ) {
        _activeBackground = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.surfaceTabBar.activeTabBackground,
            errorLog: errorLog
        ))
        _activeForeground = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.surfaceTabBar.activeTabForeground,
            errorLog: errorLog
        ))
        _inactiveBackground = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.surfaceTabBar.inactiveTabBackground,
            errorLog: errorLog
        ))
        _inactiveForeground = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.surfaceTabBar.inactiveTabForeground,
            errorLog: errorLog
        ))
        _divider = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.surfaceTabBar.tabDividerColor,
            errorLog: errorLog
        ))
        _indicator = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.surfaceTabBar.activeTabIndicatorColor,
            errorLog: errorLog
        ))
        _indicatorEdge = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.surfaceTabBar.activeTabIndicatorEdge,
            errorLog: errorLog
        ))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(
                localized: "settings.surfaceTabBar.title",
                defaultValue: "Surface Tab Bar"
            ))
            SettingsCard {
                colorRow(
                    title: String(localized: "settings.surfaceTabBar.activeBackground", defaultValue: "Active Tab Background"),
                    subtitle: String(localized: "settings.surfaceTabBar.activeBackground.subtitle", defaultValue: "Background of the selected surface tab."),
                    path: "ui.surfaceTabBar.activeTabBackground",
                    model: activeBackground,
                    fallback: Color(nsColor: .controlBackgroundColor)
                )
                SettingsCardDivider()
                colorRow(
                    title: String(localized: "settings.surfaceTabBar.activeForeground", defaultValue: "Active Tab Text"),
                    subtitle: String(localized: "settings.surfaceTabBar.activeForeground.subtitle", defaultValue: "Label color of the selected surface tab."),
                    path: "ui.surfaceTabBar.activeTabForeground",
                    model: activeForeground,
                    fallback: Color(nsColor: .labelColor)
                )
                SettingsCardDivider()
                colorRow(
                    title: String(localized: "settings.surfaceTabBar.inactiveBackground", defaultValue: "Inactive Tab Background"),
                    subtitle: String(localized: "settings.surfaceTabBar.inactiveBackground.subtitle", defaultValue: "Background of unselected surface tabs."),
                    path: "ui.surfaceTabBar.inactiveTabBackground",
                    model: inactiveBackground,
                    fallback: .clear
                )
                SettingsCardDivider()
                colorRow(
                    title: String(localized: "settings.surfaceTabBar.inactiveForeground", defaultValue: "Inactive Tab Text"),
                    subtitle: String(localized: "settings.surfaceTabBar.inactiveForeground.subtitle", defaultValue: "Label color of unselected surface tabs."),
                    path: "ui.surfaceTabBar.inactiveTabForeground",
                    model: inactiveForeground,
                    fallback: Color(nsColor: .secondaryLabelColor)
                )
                SettingsCardDivider()
                colorRow(
                    title: String(localized: "settings.surfaceTabBar.divider", defaultValue: "Tab Divider"),
                    subtitle: String(localized: "settings.surfaceTabBar.divider.subtitle", defaultValue: "Separator between neighboring surface tabs."),
                    path: "ui.surfaceTabBar.tabDividerColor",
                    model: divider,
                    fallback: Color(nsColor: .separatorColor),
                    allowsNone: true
                )
                SettingsCardDivider()
                colorRow(
                    title: String(localized: "settings.surfaceTabBar.indicator", defaultValue: "Active Tab Indicator"),
                    subtitle: String(localized: "settings.surfaceTabBar.indicator.subtitle", defaultValue: "Accent line on the selected surface tab."),
                    path: "ui.surfaceTabBar.activeTabIndicatorColor",
                    model: indicator,
                    fallback: Color(nsColor: .controlAccentColor)
                )
                SettingsCardDivider()
                indicatorEdgeRow
            }
        }
        .task {
            startSettingsObservation([
                activeBackground,
                activeForeground,
                inactiveBackground,
                inactiveForeground,
                divider,
                indicator,
                indicatorEdge,
            ])
        }
    }

    @ViewBuilder
    private func colorRow(
        title: String,
        subtitle: String,
        path: String,
        model: JSONValueModel<String>,
        fallback: Color,
        allowsNone: Bool = false
    ) -> some View {
        let isNone = model.current.caseInsensitiveCompare("none") == .orderedSame
        let isCustom = !model.current.isEmpty
        SettingsCardRow(
            configurationReview: .json(path),
            title,
            subtitle: subtitle
        ) {
            HStack(spacing: 8) {
                if allowsNone {
                    Button(isNone
                        ? String(localized: "settings.surfaceTabBar.divider.default", defaultValue: "Use Default")
                        : String(localized: "settings.surfaceTabBar.divider.none", defaultValue: "None")) {
                        if isNone { model.reset() } else { model.set("none") }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if isCustom {
                    Button(String(localized: "settings.surfaceTabBar.reset", defaultValue: "Reset")) {
                        model.reset()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if !isNone {
                    HexColorPicker(
                        storedHex: model.current,
                        fallback: fallback,
                        reconcileRevision: 0
                    ) { model.set($0) }
                }

                Text(isNone
                    ? String(localized: "settings.surfaceTabBar.none", defaultValue: "None")
                    : (isCustom
                        ? model.current
                        : String(localized: "settings.surfaceTabBar.default", defaultValue: "Default")))
                    .cmuxFont(size: 12, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
            }
        }
    }

    private var indicatorEdgeRow: some View {
        SettingsCardRow(
            configurationReview: .json("ui.surfaceTabBar.activeTabIndicatorEdge"),
            String(localized: "settings.surfaceTabBar.indicatorEdge", defaultValue: "Indicator Edge"),
            subtitle: String(localized: "settings.surfaceTabBar.indicatorEdge.subtitle", defaultValue: "Place the active-tab accent line along the top or bottom edge."),
            controlWidth: 196
        ) {
            Picker("", selection: Binding(
                get: { indicatorEdge.current },
                set: { value in
                    if value.isEmpty { indicatorEdge.reset() } else { indicatorEdge.set(value) }
                }
            )) {
                Text(String(localized: "settings.surfaceTabBar.default", defaultValue: "Default")).tag("")
                Text(String(localized: "settings.surfaceTabBar.edge.top", defaultValue: "Top")).tag("top")
                Text(String(localized: "settings.surfaceTabBar.edge.bottom", defaultValue: "Bottom")).tag("bottom")
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}
