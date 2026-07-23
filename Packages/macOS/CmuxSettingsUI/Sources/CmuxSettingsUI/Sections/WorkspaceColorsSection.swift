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
    @State private var paletteModel: DefaultsValueModel<[String: String]>
    @State private var autoColorRulesModel: DefaultsValueModel<[String: String]>
    @State private var paletteReconcileTracker = WorkspacePaletteColorReconcileTracker()

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
        _paletteModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.palette))
        _autoColorRulesModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.autoColorRules))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors"), section: .workspaceColors)
            mainCard
            autoColorRulesCard
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
            paletteModel,
            autoColorRulesModel,
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

    /// **Automatic colors** — keyword → color rules that tint any workspace
    /// whose title contains the keyword and that has no color of its own.
    ///
    /// Rules are authored in cmux.json (same story as the palette dictionary
    /// above); this card renders the effective list in match order so the
    /// precedence between overlapping keywords is visible.
    @ViewBuilder
    private var autoColorRulesCard: some View {
        let rules = orderedAutoColorRules(stored: autoColorRulesModel.current)
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("workspaceColors.autoColorRules"),
                searchAnchorID: "setting:workspaceColors:autoColorRules",
                String(localized: "settings.workspaceColors.autoColorRules", defaultValue: "Automatic Colors by Keyword"),
                subtitle: String(localized: "settings.workspaceColors.autoColorRules.subtitle", defaultValue: "Workspaces whose title contains a keyword take that color. A color set on the workspace itself always wins.")
            ) {
                EmptyView()
            }

            SettingsCardNote(
                String(localized: "settings.workspaceColors.autoColorRules.note", defaultValue: "Add rules in cmux.json under workspaceColors.autoColorRules, for example {\"deploy\": \"Red\", \"docs\": \"#1565C0\"}. Matching ignores case and accents; when several keywords match a title, the longest one wins.")
            )

            ForEach(rules, id: \.keyword) { rule in
                SettingsCardDivider()
                autoColorRuleRow(rule)
            }
        }
    }

    @ViewBuilder
    private func autoColorRuleRow(_ rule: (keyword: String, value: String, hex: String?)) -> some View {
        SettingsCardRow(
            configurationReview: .json("workspaceColors.autoColorRules"),
            rule.keyword,
            subtitle: rule.hex == nil
                ? String(localized: "settings.workspaceColors.autoColorRules.unknownColor", defaultValue: "Unknown color — use a palette name or a #RRGGBB hex.")
                : String(localized: "settings.workspaceColors.autoColorRules.matches", defaultValue: "Titles containing \"\(rule.keyword)\".")
        ) {
            HStack(spacing: 8) {
                Circle()
                    .fill(rule.hex.flatMap { NSColor(hex: $0) }.map { Color(nsColor: $0) } ?? .clear)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                    .frame(width: 14, height: 14)
                Text(rule.value)
                    .cmuxFont(size: 12, weight: .medium, design: .monospaced)
                    .foregroundStyle(rule.hex == nil ? .secondary : .primary)
                    .frame(width: 96, alignment: .trailing)
            }
        }
    }

    /// Rules in the order the app matches them: longest keyword first (most
    /// specific rule wins), then locale-independent tie-breaks. Mirrors
    /// `WorkspaceTabAutoColorRules.ruleSet` in the app target, folding
    /// included, so this list reads in the order rules actually apply.
    private func orderedAutoColorRules(
        stored: [String: String]
    ) -> [(keyword: String, value: String, hex: String?)] {
        let palette = effectivePaletteMap(stored: paletteModel.current)
        return stored
            .compactMap { rawKeyword, value -> (keyword: String, folded: String, value: String, hex: String?)? in
                let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
                let folded = keyword.folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: nil
                )
                guard !folded.isEmpty else { return nil }
                return (
                    keyword: keyword,
                    folded: folded,
                    value: value,
                    hex: resolvedRuleHex(value, palette: palette)
                )
            }
            .sorted { lhs, rhs in
                if lhs.folded.count != rhs.folded.count { return lhs.folded.count > rhs.folded.count }
                if lhs.folded != rhs.folded { return lhs.folded < rhs.folded }
                return lhs.keyword < rhs.keyword
            }
            .map { (keyword: $0.keyword, value: $0.value, hex: $0.hex) }
    }

    /// Resolves a rule value (palette name or `#RRGGBB`) to a hex, or `nil`
    /// when it names nothing in the palette.
    private func resolvedRuleHex(_ raw: String, palette: [String: String]) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        if body.count == 6, UInt64(body, radix: 16) != nil {
            return "#" + body.uppercased()
        }
        return palette.first { name, _ in name.caseInsensitiveCompare(trimmed) == .orderedSame }?.value
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
