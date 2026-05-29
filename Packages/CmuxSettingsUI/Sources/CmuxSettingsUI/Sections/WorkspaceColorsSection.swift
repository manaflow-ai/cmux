import AppKit
import CmuxSettings
import SwiftUI

/// **Workspace Colors** section — mirrors the legacy in-app section:
/// indicator-style picker, selection highlight color, notification
/// badge color, then a per-palette-entry editor and a Reset Palette
/// action.
@MainActor
public struct WorkspaceColorsSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog?

    @State private var paletteOverrides: [String: String] = [:]
    @State private var customColors: [String] = []
    @State private var overridesTask: Task<Void, Never>?
    @State private var customColorsTask: Task<Void, Never>?

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog? = nil
    ) {
        self.defaultsStore = defaultsStore
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.errorLog = errorLog
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors"))
            mainCard
        }
        .task { await observeOverrides() }
        .task { await observeCustomColors() }
        .onDisappear {
            overridesTask?.cancel()
            customColorsTask?.cancel()
        }
    }

    @ViewBuilder
    private var mainCard: some View {
        let indicator = DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.indicatorStyle)
        let selectionHex = DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.selectionColorHex)
        let badgeHex = DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.notificationBadgeColorHex)

        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("workspaceColors.indicatorStyle"),
                String(localized: "settings.workspaceColors.indicator", defaultValue: "Workspace Color Indicator"),
                controlWidth: 220
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

            if paletteOverrides.isEmpty && customColors.isEmpty {
                SettingsCardNote(
                    String(localized: "settings.workspaceColors.emptyPalette", defaultValue: "No palette entries. Add colors in cmux.json or use \"Choose Custom Color...\" from a workspace context menu.")
                )
            } else {
                let names = (Array(paletteOverrides.keys) + customColors.indices.map { "Custom \($0 + 1)" }).sorted()
                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    if index > 0 { SettingsCardDivider() }
                    paletteEntryRow(name: name)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .action,
                String(localized: "settings.workspaceColors.resetPalette", defaultValue: "Reset Palette"),
                subtitle: String(localized: "settings.workspaceColors.resetPalette.subtitleV2", defaultValue: "Restore the built-in palette and remove extra named colors.")
            ) {
                Button(String(localized: "settings.workspaceColors.resetPalette.button", defaultValue: "Reset")) {
                    resetPalette()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
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
                ColorPicker("", selection: Binding(
                    get: { colorFromHex(model.current) ?? .accentColor },
                    set: { newColor in model.set(hexFromColor(newColor)) }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 38)
                Text(isCustom ? model.current : String(localized: "settings.sidebarAppearance.defaultLabel", defaultValue: "Default"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func paletteEntryRow(name: String) -> some View {
        let hex = paletteOverrides[name] ?? "#000000"
        SettingsCardRow(
            configurationReview: .json("workspaceColors.colors"),
            name,
            subtitle: String(localized: "settings.workspaceColors.customEntry", defaultValue: "Named palette entry.")
        ) {
            HStack(spacing: 8) {
                ColorPicker("", selection: Binding(
                    get: { colorFromHex(hex) ?? .gray },
                    set: { newColor in
                        paletteOverrides[name] = hexFromColor(newColor)
                        persistOverrides()
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 38)
                Text(hex)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
                Button(String(localized: "settings.workspaceColors.remove", defaultValue: "Remove")) {
                    paletteOverrides.removeValue(forKey: name)
                    persistOverrides()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func resetPalette() {
        paletteOverrides = [:]
        customColors = []
        persistOverrides()
        persistCustomColors()
    }

    private func observeOverrides() async {
        overridesTask?.cancel()
        let task = Task {
            for await value in jsonStore.values(for: catalog.workspaceColors.paletteOverrides) {
                if Task.isCancelled { break }
                paletteOverrides = value
            }
        }
        overridesTask = task
        await task.value
    }

    private func observeCustomColors() async {
        customColorsTask?.cancel()
        let task = Task {
            for await value in jsonStore.values(for: catalog.workspaceColors.customColors) {
                if Task.isCancelled { break }
                customColors = value
            }
        }
        customColorsTask = task
        await task.value
    }

    private func persistOverrides() {
        let snapshot = paletteOverrides
        Task {
            do { try await jsonStore.set(snapshot, for: catalog.workspaceColors.paletteOverrides) }
            catch { errorLog?.record(error, keyID: catalog.workspaceColors.paletteOverrides.id) }
        }
    }

    private func persistCustomColors() {
        let snapshot = customColors
        Task {
            do { try await jsonStore.set(snapshot, for: catalog.workspaceColors.customColors) }
            catch { errorLog?.record(error, keyID: catalog.workspaceColors.customColors.id) }
        }
    }

    private func indicatorStyleLabel(_ style: WorkspaceIndicatorStyle) -> String {
        switch style {
        case .leftRail: return String(localized: "settings.workspaceColors.indicator.leftRail", defaultValue: "Left Rail")
        case .solidFill: return String(localized: "settings.workspaceColors.indicator.solidFill", defaultValue: "Solid Fill")
        }
    }

    private func colorFromHex(_ hex: String) -> Color? {
        var trimmed = hex
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let intVal = UInt32(trimmed, radix: 16) else { return nil }
        let r = Double((intVal >> 16) & 0xFF) / 255
        let g = Double((intVal >> 8) & 0xFF) / 255
        let b = Double(intVal & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }

    private func hexFromColor(_ color: Color) -> String {
        let nsColor = NSColor(color)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
