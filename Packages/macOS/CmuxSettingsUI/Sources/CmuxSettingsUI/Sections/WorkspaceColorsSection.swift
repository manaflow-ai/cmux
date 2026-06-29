import CmuxFoundation
import AppKit
import CmuxSettings
import SwiftUI

/// **Workspace Colors** section — mirrors the legacy in-app section:
/// indicator-style picker, selection highlight color, notification
/// badge color, then a per-palette-entry editor and a Reset Palette
/// action.
@MainActor
public struct WorkspaceColorsSection: View {
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog

    @State private var indicator: DefaultsValueModel<WorkspaceIndicatorStyle>
    @State private var selectionHex: DefaultsValueModel<String>
    @State private var badgeHex: DefaultsValueModel<String>
    @State private var stateColorsEnabled: DefaultsValueModel<Bool>
    @State private var stateColorMode: DefaultsValueModel<WorkspaceStateColorMode>
    @State private var stateColors: DefaultsValueModel<[String: String]>
    @State private var paletteModel: DefaultsValueModel<[String: String]>
    @State private var paletteReconcileTracker = WorkspacePaletteColorReconcileTracker()

    private struct AgentStateColorRow: Identifiable {
        let rawValue: String
        let title: String
        let defaultHex: String?

        var id: String { rawValue }
    }

    /// Built-in palette order and default hexes. Mirrors
    /// `WorkspaceTabColorSettings.defaultPalette` in the legacy app target.
    /// Kept in this file so the section can render the full effective
    /// palette (built-ins + customs) with `Base:` subtitles and Remove
    /// gating without reaching outside the package.
    private static let builtInPalette: [(name: String, hex: String)] = [
        ("Red", "#C0392B"),
        ("Crimson", "#922B21"),
        ("Orange", "#A04000"),
        ("Amber", "#7D6608"),
        ("Olive", "#4A5C18"),
        ("Green", "#196F3D"),
        ("Teal", "#006B6B"),
        ("Aqua", "#0E6B8C"),
        ("Blue", "#1565C0"),
        ("Navy", "#1A5276"),
        ("Indigo", "#283593"),
        ("Purple", "#6A1B9A"),
        ("Magenta", "#AD1457"),
        ("Rose", "#880E4F"),
        ("Brown", "#7B3F00"),
        ("Charcoal", "#3E4B5E"),
    ]

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog
    ) {
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.errorLog = errorLog
        _indicator = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.indicatorStyle))
        _selectionHex = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.selectionColorHex))
        _badgeHex = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.notificationBadgeColorHex))
        _stateColorsEnabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.stateColorsEnabled))
        _stateColorMode = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.stateColorMode))
        _stateColors = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.stateColors))
        _paletteModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.palette))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors"), section: .workspaceColors)
            mainCard
        }
        .task {
            startObservingSettings()
            paletteReconcileTracker.startTracking(effectivePaletteMap(stored: paletteModel.current))
        }
        .onChange(of: paletteModel.current) { _, newPalette in
            paletteReconcileTracker.reconcileExternalHexes(effectivePaletteMap(stored: newPalette))
        }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            indicator,
            selectionHex,
            badgeHex,
            stateColorsEnabled,
            stateColorMode,
            stateColors,
            paletteModel,
        ]
        models.forEach { $0.startObserving() }
    }

    @ViewBuilder
    private var mainCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("workspaceColors.indicatorStyle"),
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
                json: "workspaceColors.selectionColor",
                resetLabel: String(localized: "settings.workspaceColors.selectionColor.reset", defaultValue: "Reset"),
                model: selectionHex
            )
            SettingsCardDivider()
            colorRow(
                title: String(localized: "settings.workspaceColors.notificationBadgeColor", defaultValue: "Notification Badge"),
                subtitle: String(localized: "settings.workspaceColors.notificationBadgeColor.subtitle", defaultValue: "Color of the unread notification badge on workspace tabs."),
                json: "workspaceColors.notificationBadgeColor",
                resetLabel: String(localized: "settings.workspaceColors.notificationBadgeColor.reset", defaultValue: "Reset"),
                model: badgeHex
            )
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("workspaceColors.stateColorsEnabled"),
                String(localized: "settings.workspaceColors.stateColorsEnabled", defaultValue: "Agent State Colors"),
                subtitle: String(localized: "settings.workspaceColors.stateColorsEnabled.subtitle", defaultValue: "Tint sidebar workspace tabs from the current agent state.")
            ) {
                Toggle("", isOn: Binding(get: { stateColorsEnabled.current }, set: { stateColorsEnabled.set($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("workspaceColors.stateColorMode"),
                String(localized: "settings.workspaceColors.stateColorMode", defaultValue: "State Color Behavior"),
                subtitle: String(localized: "settings.workspaceColors.stateColorMode.subtitle", defaultValue: "Choose how state colors interact with manual workspace colors."),
                controlWidth: 196
            ) {
                Picker("", selection: Binding(get: { stateColorMode.current }, set: { stateColorMode.set($0) })) {
                    ForEach(WorkspaceStateColorMode.allCases, id: \.self) { mode in
                        Text(stateColorModeLabel(mode)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()

            ForEach(agentStateColorRows()) { row in
                stateColorRow(row)
                SettingsCardDivider()
            }

            SettingsCardNote(
                String(localized: "settings.workspaceColors.dictionaryNote", defaultValue: "Edit cmux.json to add or remove named colors. \"Choose Custom Color...\" still adds local Custom N entries.")
            )

            let entries = effectivePaletteEntries(overrides: paletteModel.current)
            if entries.isEmpty {
                SettingsCardNote(
                    String(localized: "settings.workspaceColors.emptyPalette", defaultValue: "No palette entries. Add colors in cmux.json or use \"Choose Custom Color...\" from a workspace context menu.")
                )
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.name) { index, entry in
                    if index > 0 { SettingsCardDivider() }
                    paletteEntryRow(entry: entry, paletteModel: paletteModel)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .action,
                searchAnchorID: "setting:workspaceColors:palette",
                String(localized: "settings.workspaceColors.resetPalette", defaultValue: "Reset Palette"),
                subtitle: String(localized: "settings.workspaceColors.resetPalette.subtitleV2", defaultValue: "Restore the built-in palette and remove extra named colors.")
            ) {
                Button(String(localized: "settings.workspaceColors.resetPalette.button", defaultValue: "Reset")) {
                    paletteModel.reset()
                    paletteReconcileTracker.recordPaletteReset(resultingHexes: effectivePaletteMap(stored: [:]))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func stateColorRow(_ row: AgentStateColorRow) -> some View {
        let currentHex = stateColors.current[row.rawValue]
        SettingsCardRow(
            configurationReview: .json("workspaceColors.stateColors"),
            searchAnchorID: "setting:workspaceColors:state-colors-\(row.rawValue)",
            row.title
        ) {
            HStack(spacing: 8) {
                if currentHex != nil {
                    Button(String(localized: "settings.workspaceColors.stateColor.clear", defaultValue: "Clear")) {
                        setStateColor(nil, for: row.rawValue)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if currentHex != row.defaultHex {
                    Button(String(localized: "settings.workspaceColors.stateColor.reset", defaultValue: "Reset")) {
                        setStateColor(row.defaultHex, for: row.rawValue)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                ColorPicker("", selection: Binding(
                    get: { Color(cmuxHex: currentHex ?? row.defaultHex ?? "#8E8E93") ?? Color(nsColor: .systemBlue) },
                    set: { newColor in setStateColor(newColor.cmuxHexString, for: row.rawValue) }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 38)
                Text(currentHex ?? String(localized: "settings.workspaceColors.stateColor.noTint", defaultValue: "No tint"))
                    .cmuxFont(size: 12, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
            }
        }
    }

    private func setStateColor(_ hex: String?, for rawValue: String) {
        var snapshot = stateColors.current
        if let hex {
            snapshot[rawValue] = hex
        } else {
            snapshot.removeValue(forKey: rawValue)
        }
        stateColors.set(snapshot)
    }

    @ViewBuilder
    private func colorRow(title: String, subtitle: String, json: String, resetLabel: String, model: DefaultsValueModel<String>) -> some View {
        let isCustom = !model.current.isEmpty
        SettingsCardRow(
            configurationReview: .json(json),
            title,
            subtitle: subtitle
        ) {
            HStack(spacing: 8) {
                if isCustom {
                    Button(resetLabel) { model.reset() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                HexColorPicker(
                    storedHex: model.current,
                    fallback: Self.cmuxAccentColor(),
                    reconcileRevision: model.revision
                ) { hex in
                    model.set(hex)
                }
                Text(isCustom ? model.current : String(localized: "settings.sidebarAppearance.defaultLabel", defaultValue: "Default"))
                    .cmuxFont(size: 12, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func paletteEntryRow(
        entry: (name: String, hex: String),
        paletteModel: DefaultsValueModel<[String: String]>
    ) -> some View {
        let baseHex = baseHex(for: entry.name)
        let subtitle: String = {
            if let baseHex {
                return String(localized: "settings.workspaceColors.base", defaultValue: "Base: \(baseHex)")
            }
            return String(localized: "settings.workspaceColors.customEntry", defaultValue: "Named palette entry.")
        }()
        SettingsCardRow(
            configurationReview: .json("workspaceColors.colors"),
            entry.name,
            subtitle: subtitle
        ) {
            HStack(spacing: 8) {
                HexColorPicker(
                    storedHex: entry.hex,
                    fallback: Color(nsColor: .systemBlue),
                    reconcileRevision: paletteReconcileTracker.revision(for: entry.name)
                ) { hex in
                    // Legacy semantics: persist the full effective
                    // palette (built-ins filled in at their default
                    // hex when missing) so editing one entry never
                    // drops the rest.
                    var snapshot = effectivePaletteMap(stored: paletteModel.current)
                    snapshot[entry.name] = hex
                    paletteModel.set(snapshot)
                    paletteReconcileTracker.recordPickerWrite(name: entry.name, resultingHexes: snapshot)
                }
                Text(entry.hex)
                    .cmuxFont(size: 12, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
                if baseHex == nil {
                    Button(String(localized: "settings.workspaceColors.remove", defaultValue: "Remove")) {
                        var snapshot = effectivePaletteMap(stored: paletteModel.current)
                        snapshot.removeValue(forKey: entry.name)
                        paletteModel.set(snapshot)
                        paletteReconcileTracker.reconcileExternalHexes(snapshot)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    /// Returns the effective palette entries: built-in entries first
    /// (in `builtInPalette` order, with overrides applied or default
    /// hex), followed by custom entries sorted by name. Mirrors
    /// `WorkspaceTabColorSettings.palette()`.
    private func effectivePaletteEntries(overrides: [String: String]) -> [(name: String, hex: String)] {
        let resolved = effectivePaletteMap(stored: overrides)
        let builtInNames = Set(Self.builtInPalette.map(\.name))
        let builtIn: [(name: String, hex: String)] = Self.builtInPalette.compactMap { entry in
            guard let hex = resolved[entry.name] else { return nil }
            return (name: entry.name, hex: hex)
        }
        let customs = resolved
            .filter { !builtInNames.contains($0.key) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { (name: $0.key, hex: $0.value) }
        return builtIn + customs
    }

    /// Returns the full effective palette dictionary. When `stored` is
    /// empty (no UserDefaults entry yet) this is the built-in default
    /// palette; otherwise the stored map is returned verbatim. Matches
    /// legacy `WorkspaceTabColorSettings.effectivePaletteMap`.
    private func effectivePaletteMap(stored: [String: String]) -> [String: String] {
        if stored.isEmpty {
            return Dictionary(uniqueKeysWithValues: Self.builtInPalette.map { ($0.name, $0.hex) })
        }
        return stored
    }

    private func baseHex(for name: String) -> String? {
        Self.builtInPalette.first(where: { $0.name == name })?.hex
    }

    /// Localized label for an indicator style.
    ///
    /// Uses the legacy `sidebar.activeTabIndicator.*` localization keys
    /// (mirrors `SidebarActiveTabIndicatorStyle.displayName` in the app
    /// target) so existing translations apply.
    private func indicatorStyleLabel(_ style: WorkspaceIndicatorStyle) -> String {
        switch style {
        case .leftRail: return String(localized: "sidebar.activeTabIndicator.leftRail", defaultValue: "Left Rail")
        case .solidFill: return String(localized: "sidebar.activeTabIndicator.solidFill", defaultValue: "Solid Fill")
        }
    }

    private func stateColorModeLabel(_ mode: WorkspaceStateColorMode) -> String {
        switch mode {
        case .replace:
            return String(localized: "settings.workspaceColors.stateColorMode.replace", defaultValue: "Replace Manual Color")
        case .blend:
            return String(localized: "settings.workspaceColors.stateColorMode.blend", defaultValue: "Blend With Manual Color")
        }
    }

    private func agentStateColorRows() -> [AgentStateColorRow] {
        [
            AgentStateColorRow(
                rawValue: "running",
                title: String(localized: "settings.workspaceColors.stateColor.running", defaultValue: "Running"),
                defaultHex: WorkspaceColorsCatalogSection.defaultStateColors["running"]
            ),
            AgentStateColorRow(
                rawValue: "needsInput",
                title: String(localized: "settings.workspaceColors.stateColor.needsInput", defaultValue: "Needs Input"),
                defaultHex: WorkspaceColorsCatalogSection.defaultStateColors["needsInput"]
            ),
            AgentStateColorRow(
                rawValue: "idle",
                title: String(localized: "settings.workspaceColors.stateColor.idle", defaultValue: "Idle"),
                defaultHex: WorkspaceColorsCatalogSection.defaultStateColors["idle"]
            ),
            AgentStateColorRow(
                rawValue: "unknown",
                title: String(localized: "settings.workspaceColors.stateColor.unknown", defaultValue: "Unknown"),
                defaultHex: WorkspaceColorsCatalogSection.defaultStateColors["unknown"]
            ),
        ]
    }


    /// cmux-themed accent color used as the live ColorPicker fallback
    /// when the selection or notification badge has no custom hex.
    /// Mirrors the legacy `cmuxAccentColor()` helper (see
    /// `Sources/Sidebar/SidebarAppearanceSupport.swift`) so the rendered
    /// swatch matches the rest of the app instead of the system accent.
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
