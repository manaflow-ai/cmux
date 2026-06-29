import AppKit
import CmuxFoundation
import CmuxSettings
import CoreText
import SwiftUI

/// **Appearance** section: app theme, terminal font, UI text sizing, sidebar
/// backdrop behavior, and workspace colors in one Settings pane.
@MainActor
public struct AppearanceSection: View {
    private let hostActions: SettingsHostActions

    @State private var appAppearance: DefaultsValueModel<AppearanceMode>
    @State private var globalFontMagnification: DefaultsValueModel<Int>
    @State private var matchTerminal: DefaultsValueModel<Bool>
    @State private var indicator: DefaultsValueModel<WorkspaceIndicatorStyle>
    @State private var selectionHex: DefaultsValueModel<String>
    @State private var badgeHex: DefaultsValueModel<String>

    @State private var terminalFontFamily: String
    @State private var terminalFontSize: SettingsFontSize
    @State private var terminalFontFamilies: [String]
    @State private var terminalFontFamilySaveFailed = false
    @State private var terminalFontSizeSaveFailed = false
    @State private var terminalFontFamilySaveGeneration = 0
    @State private var terminalFontSizeSaveGeneration = 0
    @State private var terminalFontFamilySaveTask: Task<Void, Never>?
    @State private var terminalFontSizeSaveTask: Task<Void, Never>?

    @State private var sidebarFont: SettingsFontSize
    @State private var sidebarFontSaveFailed = false
    @State private var sidebarFontSaveGeneration = 0
    @State private var sidebarFontSaveTask: Task<Void, Never>?

    @State private var surfaceTabBarFont: SettingsFontSize
    @State private var surfaceTabBarFontSaveFailed = false
    @State private var surfaceTabBarFontSaveGeneration = 0
    @State private var surfaceTabBarFontSaveTask: Task<Void, Never>?

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions
    ) {
        self.hostActions = hostActions
        _appAppearance = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.appearance))
        _globalFontMagnification = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.app.globalFontMagnification))
        _matchTerminal = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebarAppearance.matchTerminalBackground))
        _indicator = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.indicatorStyle))
        _selectionHex = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.selectionColorHex))
        _badgeHex = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.notificationBadgeColorHex))
        _terminalFontFamily = State(initialValue: hostActions.terminalFontFamily())
        _terminalFontSize = State(initialValue: hostActions.terminalFontSize())
        _terminalFontFamilies = State(initialValue: [])
        _sidebarFont = State(initialValue: hostActions.sidebarFontSize())
        _surfaceTabBarFont = State(initialValue: hostActions.surfaceTabBarFontSize())
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.appearance", defaultValue: "Appearance"), section: .appearance)
            appThemeCard
            terminalFontCard
            interfaceTextCard
            sidebarCard
            workspaceColorsCard
        }
        .task {
            startObservingSettings()
            await loadTerminalFontFamiliesIfNeeded()
        }
    }

    private var globalFontMagnificationSubtitle: String {
        if globalFontMagnification.current != GlobalFontMagnification.defaultPercent {
            return String(
                localized: "settings.app.globalFontMagnification.subtitleOn",
                defaultValue: "Terminals, tabs, and chrome all render at this magnification. Per-pane zoom (Cmd= / Cmd-) still overrides for the focused pane."
            )
        }
        return String(
            localized: "settings.app.globalFontMagnification.subtitleOff",
            defaultValue: "Scale every font in cmux by the same percentage. 100% = design size."
        )
    }

    private var terminalFontFamilyChoices: [String] {
        var choices = terminalFontFamilies
        let current = terminalFontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = [CmuxGhosttyConfigSettingEditor.defaultTerminalFontFamily, current]
        for family in defaults where !family.isEmpty && !choices.contains(family) {
            choices.insert(family, at: 0)
        }
        return choices
    }

    private var terminalFontSaveFailed: Bool {
        terminalFontFamilySaveFailed || terminalFontSizeSaveFailed
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            appAppearance,
            globalFontMagnification,
            matchTerminal,
            indicator,
            selectionHex,
            badgeHex,
        ]
        models.forEach { $0.startObserving() }
    }

    private func loadTerminalFontFamiliesIfNeeded() async {
        guard terminalFontFamilies.isEmpty else { return }
        let families = await Task.detached(priority: .userInitiated) {
            Self.monospacedFontFamilies()
        }.value
        guard !Task.isCancelled else { return }
        terminalFontFamilies = families
    }

    private func setGlobalFontMagnification(_ percent: Int) {
        let clamped = GlobalFontMagnification.clamp(percent)
        globalFontMagnification.set(clamped) {
            NotificationCenter.default.post(name: GlobalFontMagnification.didChangeNotification, object: nil)
        }
    }

    private func saveTerminalFontFamily(_ family: String) {
        terminalFontFamilySaveGeneration += 1
        let generation = terminalFontFamilySaveGeneration
        terminalFontFamilySaveTask?.cancel()
        terminalFontFamilySaveTask = Task {
            await Task.yield()
            guard !Task.isCancelled, generation == terminalFontFamilySaveGeneration else { return }
            let saved = await hostActions.setTerminalFontFamily(family)
            if !Task.isCancelled, generation == terminalFontFamilySaveGeneration { terminalFontFamilySaveFailed = !saved }
        }
    }

    private func saveTerminalFontSize(_ points: Double) {
        terminalFontSizeSaveGeneration += 1
        let generation = terminalFontSizeSaveGeneration
        terminalFontSizeSaveTask?.cancel()
        terminalFontSizeSaveTask = Task {
            await Task.yield()
            guard !Task.isCancelled, generation == terminalFontSizeSaveGeneration else { return }
            let saved = await hostActions.setTerminalFontSize(points)
            if !Task.isCancelled, generation == terminalFontSizeSaveGeneration { terminalFontSizeSaveFailed = !saved }
        }
    }

    private func resetTerminalFont() {
        terminalFontFamily = CmuxGhosttyConfigSettingEditor.defaultTerminalFontFamily
        terminalFontSize.points = terminalFontSize.defaultValue
        saveTerminalFontFamily(terminalFontFamily)
        saveTerminalFontSize(terminalFontSize.points)
    }

    private func saveSidebarFontSize(_ points: Double) {
        sidebarFontSaveGeneration += 1
        let generation = sidebarFontSaveGeneration
        sidebarFontSaveTask?.cancel()
        sidebarFontSaveTask = Task {
            await Task.yield()
            guard !Task.isCancelled, generation == sidebarFontSaveGeneration else { return }
            let saved = await hostActions.setSidebarFontSize(points)
            if !Task.isCancelled, generation == sidebarFontSaveGeneration { sidebarFontSaveFailed = !saved }
        }
    }

    private func saveSurfaceTabBarFontSize(_ points: Double) {
        surfaceTabBarFontSaveGeneration += 1
        let generation = surfaceTabBarFontSaveGeneration
        surfaceTabBarFontSaveTask?.cancel()
        surfaceTabBarFontSaveTask = Task {
            await Task.yield()
            guard !Task.isCancelled, generation == surfaceTabBarFontSaveGeneration else { return }
            let saved = await hostActions.setSurfaceTabBarFontSize(points)
            if !Task.isCancelled, generation == surfaceTabBarFontSaveGeneration { surfaceTabBarFontSaveFailed = !saved }
        }
    }

    @ViewBuilder
    private var appThemeCard: some View {
        SettingsCard {
            ThemePickerRow(
                selectedMode: appAppearance.current,
                onSelect: { appAppearance.set($0) }
            )
            .settingsSearchAnchors(["setting:appearance:appearance"])
        }
    }

    @ViewBuilder
    private var terminalFontCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:appearance:terminal-font",
                String(localized: "settings.appearance.terminalFont", defaultValue: "Terminal Font"),
                subtitle: String(localized: "settings.appearance.terminalFont.subtitle", defaultValue: "Choose the monospace font family and size used by terminal panes."),
                controlWidth: 380
            ) {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        Picker(
                            "",
                            selection: Binding(
                                get: { terminalFontFamily },
                                set: { newFamily in
                                    terminalFontFamily = newFamily
                                    saveTerminalFontFamily(newFamily)
                                }
                            )
                        ) {
                            ForEach(terminalFontFamilyChoices, id: \.self) { family in
                                Text(family).tag(family)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                        .accessibilityLabel(String(localized: "settings.appearance.terminalFont.family", defaultValue: "Terminal Font Family"))
                        .accessibilityIdentifier("SettingsTerminalFontFamilyPicker")

                        Stepper(
                            value: Binding(
                                get: { terminalFontSize.points },
                                set: { newValue in
                                    terminalFontSize.points = newValue
                                    saveTerminalFontSize(newValue)
                                }
                            ),
                            in: terminalFontSize.minimum...terminalFontSize.maximum,
                            step: 0.5
                        ) {
                            Text(String.localizedStringWithFormat(String(localized: "settings.fontSize.valuePoints", defaultValue: "%@ pt"), hostActions.formattedFontSize(terminalFontSize.points)))
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                        .controlSize(.small)
                        .accessibilityLabel(String(localized: "settings.appearance.terminalFont.size", defaultValue: "Terminal Font Size"))
                        .accessibilityIdentifier("SettingsTerminalFontSizeStepper")

                        Button(String(localized: "settings.appearance.terminalFont.reset", defaultValue: "Reset")) {
                            resetTerminalFont()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(
                            terminalFontFamily == CmuxGhosttyConfigSettingEditor.defaultTerminalFontFamily &&
                                terminalFontSize.isDefault
                        )
                    }

                    if terminalFontSaveFailed {
                        Text(String(localized: "settings.appearance.terminalFont.saveFailed", defaultValue: "Couldn't save terminal font. Please try again."))
                            .cmuxFont(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var interfaceTextCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("app.globalFontMagnification"),
                searchAnchorID: "setting:appearance:global-font-magnification",
                String(localized: "settings.app.globalFontMagnification", defaultValue: "Global Font Magnification"),
                subtitle: globalFontMagnificationSubtitle
            ) {
                GlobalFontMagnificationControl(
                    percent: globalFontMagnification.current,
                    onChange: setGlobalFontMagnification
                )
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:appearance:sidebar-font-size",
                String(localized: "settings.sidebarAppearance.fontSize", defaultValue: "Sidebar Font Size"),
                subtitle: String(localized: "settings.sidebarAppearance.fontSize.subtitle", defaultValue: "Controls workspace titles, metadata, badges, and shortcut hints in the left sidebar."),
                controlWidth: 250
            ) {
                fontSizeSlider(
                    value: Binding(get: { sidebarFont.points }, set: { sidebarFont.points = $0 }),
                    range: sidebarFont.minimum...sidebarFont.maximum,
                    resetDisabled: sidebarFont.isDefault,
                    saveFailed: sidebarFontSaveFailed,
                    saveFailedText: String(localized: "settings.sidebarAppearance.fontSize.saveFailed", defaultValue: "Couldn't save sidebar font size. Please try again."),
                    accessibilityIdentifier: "SettingsSidebarFontSizeSlider",
                    resetTitle: String(localized: "settings.sidebarAppearance.fontSize.reset", defaultValue: "Reset"),
                    onCommit: { saveSidebarFontSize(sidebarFont.points) },
                    onReset: {
                        sidebarFont.points = sidebarFont.defaultValue
                        saveSidebarFontSize(sidebarFont.points)
                    }
                )
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:appearance:tab-bar-font-size",
                String(localized: "settings.terminal.tabBarFontSize", defaultValue: "Tab Bar Font Size"),
                subtitle: String(localized: "settings.terminal.tabBarFontSize.subtitle", defaultValue: "Controls the font size of the terminal and browser tab titles at the top of each pane."),
                controlWidth: 250
            ) {
                fontSizeSlider(
                    value: Binding(get: { surfaceTabBarFont.points }, set: { surfaceTabBarFont.points = $0 }),
                    range: surfaceTabBarFont.minimum...surfaceTabBarFont.maximum,
                    resetDisabled: surfaceTabBarFont.isDefault,
                    saveFailed: surfaceTabBarFontSaveFailed,
                    saveFailedText: String(localized: "settings.terminal.tabBarFontSize.saveFailed", defaultValue: "Couldn't save tab bar font size. Please try again."),
                    accessibilityIdentifier: "SettingsTabBarFontSizeSlider",
                    resetTitle: String(localized: "settings.terminal.tabBarFontSize.reset", defaultValue: "Reset"),
                    onCommit: { saveSurfaceTabBarFontSize(surfaceTabBarFont.points) },
                    onReset: {
                        surfaceTabBarFont.points = surfaceTabBarFont.defaultValue
                        saveSurfaceTabBarFontSize(surfaceTabBarFont.points)
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var sidebarCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("sidebarAppearance.matchTerminalBackground"),
                searchAnchorID: "setting:appearance:match-terminal",
                String(localized: "settings.sidebarAppearance.matchTerminalBackground", defaultValue: "Match Terminal Background"),
                subtitle: String(localized: "settings.sidebarAppearance.matchTerminalBackground.subtitle", defaultValue: "Use the same background color and transparency as the terminal.")
            ) {
                Toggle("", isOn: Binding(get: { matchTerminal.current }, set: { matchTerminal.set($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var workspaceColorsCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("workspaceColors.indicatorStyle"),
                searchAnchorID: "setting:appearance:workspace-color-indicator",
                String(localized: "settings.workspaceColors.indicator", defaultValue: "Workspace Color Indicator"),
                controlWidth: 196
            ) {
                Picker("", selection: Binding(get: { indicator.current }, set: { indicator.set($0) })) {
                    ForEach(WorkspaceIndicatorStyle.allCases, id: \.self) { style in
                        Text(indicatorStyleLabel(style)).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            colorRow(
                title: String(localized: "settings.workspaceColors.selectionColor", defaultValue: "Selection Highlight"),
                subtitle: String(localized: "settings.workspaceColors.selectionColor.subtitle", defaultValue: "Background color of the selected workspace in the sidebar."),
                searchAnchorID: "setting:appearance:workspace-selection-highlight",
                json: "workspaceColors.selectionColor",
                resetLabel: String(localized: "settings.workspaceColors.selectionColor.reset", defaultValue: "Reset"),
                model: selectionHex
            )
            SettingsCardDivider()

            colorRow(
                title: String(localized: "settings.workspaceColors.notificationBadgeColor", defaultValue: "Notification Badge"),
                subtitle: String(localized: "settings.workspaceColors.notificationBadgeColor.subtitle", defaultValue: "Color of the unread notification badge on workspace tabs."),
                searchAnchorID: "setting:appearance:workspace-notification-badge",
                json: "workspaceColors.notificationBadgeColor",
                resetLabel: String(localized: "settings.workspaceColors.notificationBadgeColor.reset", defaultValue: "Reset"),
                model: badgeHex
            )
        }
    }

    @ViewBuilder
    private func fontSizeSlider(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        resetDisabled: Bool,
        saveFailed: Bool,
        saveFailedText: String,
        accessibilityIdentifier: String,
        resetTitle: String,
        onCommit: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: 0.5) { editing in
                    if !editing { onCommit() }
                }
                .frame(width: 130)
                .accessibilityIdentifier(accessibilityIdentifier)

                Text(String.localizedStringWithFormat(String(localized: "settings.fontSize.valuePoints", defaultValue: "%@ pt"), hostActions.formattedFontSize(value.wrappedValue)))
                    .cmuxFont(size: 12, weight: .medium, design: .rounded)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)

                Button(resetTitle) {
                    onReset()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(resetDisabled)
            }

            if saveFailed {
                Text(saveFailedText)
                    .cmuxFont(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func colorRow(title: String, subtitle: String, searchAnchorID: String, json: String, resetLabel: String, model: DefaultsValueModel<String>) -> some View {
        let isCustom = !model.current.isEmpty
        SettingsCardRow(
            configurationReview: .json(json),
            searchAnchorID: searchAnchorID,
            title,
            subtitle: subtitle
        ) {
            HStack(spacing: 8) {
                if isCustom {
                    Button(resetLabel) { model.reset() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                ColorPicker("", selection: Binding(
                    get: { Color(cmuxHex: model.current) ?? Self.cmuxAccentColor() },
                    set: { newColor in model.set(newColor.cmuxHexString) }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 38)
                Text(isCustom ? model.current : String(localized: "settings.sidebarAppearance.defaultLabel", defaultValue: "Default"))
                    .cmuxFont(size: 12, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
            }
        }
    }

    private func indicatorStyleLabel(_ style: WorkspaceIndicatorStyle) -> String {
        switch style {
        case .leftRail: return String(localized: "sidebar.activeTabIndicator.leftRail", defaultValue: "Left Rail")
        case .solidFill: return String(localized: "sidebar.activeTabIndicator.solidFill", defaultValue: "Solid Fill")
        }
    }

    nonisolated private static func monospacedFontFamilies() -> [String] {
        let families = (CTFontManagerCopyAvailableFontFamilyNames() as NSArray)
            .compactMap { $0 as? String }
        return families
            .filter(isMonospacedFamily)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated private static func isMonospacedFamily(_ family: String) -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family
        ] as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor] ?? []
        return matches.contains { descriptor in
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            return CTFontGetSymbolicTraits(font).contains(.traitMonoSpace)
        }
    }

    private static func cmuxAccentColor() -> Color {
        let nsColor = NSColor(name: nil) { appearance in
            let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
            if bestMatch == .darkAqua {
                return NSColor(srgbRed: 0, green: 145.0 / 255.0, blue: 1.0, alpha: 1.0)
            }
            return NSColor(srgbRed: 0, green: 136.0 / 255.0, blue: 1.0, alpha: 1.0)
        }
        return Color(nsColor: nsColor)
    }
}
