import AppKit
import CmuxSettings
import SwiftUI

/// Sidebar material controls, kept separate from the workspace-detail card so
/// changing blur/tint invalidates only this small settings subtree.
@MainActor
struct SidebarMaterialCard: View {
    @State private var matchTerminal: DefaultsValueModel<Bool>
    @State private var preset: DefaultsValueModel<SidebarPresetOption>
    @State private var material: DefaultsValueModel<SidebarMaterialOption>
    @State private var blendMode: DefaultsValueModel<SidebarBlendModeOption>
    @State private var state: DefaultsValueModel<SidebarStateOption>
    @State private var tintHex: DefaultsValueModel<String>
    @State private var tintOpacity: DefaultsValueModel<Double>
    @State private var blurOpacity: DefaultsValueModel<Double>
    @State private var cornerRadius: DefaultsValueModel<Double>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        let section = catalog.sidebarAppearance
        _matchTerminal = State(initialValue: DefaultsValueModel(store: defaultsStore, key: section.matchTerminalBackground))
        _preset = State(initialValue: DefaultsValueModel(store: defaultsStore, key: section.preset))
        _material = State(initialValue: DefaultsValueModel(store: defaultsStore, key: section.material))
        _blendMode = State(initialValue: DefaultsValueModel(store: defaultsStore, key: section.blendMode))
        _state = State(initialValue: DefaultsValueModel(store: defaultsStore, key: section.state))
        _tintHex = State(initialValue: DefaultsValueModel(store: defaultsStore, key: section.tintColorHex))
        _tintOpacity = State(initialValue: DefaultsValueModel(store: defaultsStore, key: section.tintOpacity))
        _blurOpacity = State(initialValue: DefaultsValueModel(store: defaultsStore, key: section.blurOpacity))
        _cornerRadius = State(initialValue: DefaultsValueModel(store: defaultsStore, key: section.cornerRadius))
    }

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:sidebarAppearance:sidebar-style",
                String(localized: "settings.sidebarAppearance.preset", defaultValue: "Sidebar Style"),
                subtitle: String(localized: "settings.sidebarAppearance.preset.subtitle", defaultValue: "Liquid Glass Sidebars keeps terminal and browser panes opaque.")
            ) {
                Picker("", selection: presetBinding) {
                    ForEach(SidebarPresetOption.allCases, id: \.self) { option in
                        Text(presetTitle(option)).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 210)
            }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebarAppearance.matchTerminalBackground"),
                String(localized: "settings.sidebarAppearance.matchTerminalBackground", defaultValue: "Match Terminal Background"),
                subtitle: matchTerminal.current
                    ? String(localized: "settings.sidebarAppearance.matchTerminalBackground.subtitleOn", defaultValue: "Sidebars use the terminal background instead of their own material.")
                    : String(localized: "settings.sidebarAppearance.matchTerminalBackground.subtitleOff", defaultValue: "Sidebars use an independent material; terminal and browser panes stay opaque.")
            ) {
                Toggle("", isOn: Binding(get: { matchTerminal.current }, set: { matchTerminal.set($0); preset.set(.custom) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsCardDivider()

            pickerRow(
                title: String(localized: "settings.sidebarAppearance.material", defaultValue: "Material"),
                json: "sidebarAppearance.material",
                value: material.current,
                options: SidebarMaterialOption.allCases,
                label: materialTitle
            ) { material.set($0); preset.set(.custom) }
            SettingsCardDivider()
            pickerRow(
                title: String(localized: "settings.sidebarAppearance.blendMode", defaultValue: "Blending"),
                json: "sidebarAppearance.blendMode",
                value: blendMode.current,
                options: SidebarBlendModeOption.allCases,
                label: blendModeTitle
            ) { blendMode.set($0); preset.set(.custom) }
            SettingsCardDivider()
            pickerRow(
                title: String(localized: "settings.sidebarAppearance.state", defaultValue: "Window State"),
                json: "sidebarAppearance.state",
                value: state.current,
                options: SidebarStateOption.allCases,
                label: stateTitle
            ) { state.set($0); preset.set(.custom) }
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("sidebarAppearance.tintColor"),
                String(localized: "settings.sidebarAppearance.tintColor", defaultValue: "Tint Color")
            ) {
                HStack(spacing: 8) {
                    HexColorPicker(
                        storedHex: tintHex.current,
                        fallback: .black,
                        reconcileRevision: tintHex.revision
                    ) { value in
                        tintHex.set(value)
                        preset.set(.custom)
                    }
                    Text(tintHex.current)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .trailing)
                }
            }
            SettingsCardDivider()
            sliderRow(
                title: String(localized: "settings.sidebarAppearance.tintOpacity", defaultValue: "Tint Opacity"),
                json: "sidebarAppearance.tintOpacity",
                value: tintOpacity.current,
                range: 0...1,
                format: .percent.precision(.fractionLength(0))
            ) { tintOpacity.set($0); preset.set(.custom) }
            SettingsCardDivider()
            sliderRow(
                title: String(localized: "settings.sidebarAppearance.blurOpacity", defaultValue: "Material Strength"),
                json: "sidebarAppearance.blurOpacity",
                value: blurOpacity.current,
                range: 0...1,
                format: .percent.precision(.fractionLength(0))
            ) { blurOpacity.set($0); preset.set(.custom) }
            SettingsCardDivider()
            sliderRow(
                title: String(localized: "settings.sidebarAppearance.cornerRadius", defaultValue: "Corner Radius"),
                json: "sidebarAppearance.cornerRadius",
                value: cornerRadius.current,
                range: 0...40,
                format: .number.precision(.fractionLength(0))
            ) { cornerRadius.set($0); preset.set(.custom) }
        }
        .task {
            let models: [any SettingObservationStarting] = [
                matchTerminal, preset, material, blendMode, state,
                tintHex, tintOpacity, blurOpacity, cornerRadius,
            ]
            models.forEach { $0.startObserving() }
        }
    }

    private var presetBinding: Binding<SidebarPresetOption> {
        Binding(
            get: { preset.current },
            set: { option in
                preset.set(option)
                apply(option)
            }
        )
    }

    private func apply(_ option: SidebarPresetOption) {
        switch option {
        case .liquidGlassSidebars:
            matchTerminal.set(false)
            material.set(.liquidGlass)
            blendMode.set(.withinWindow)
            state.set(.followWindow)
            tintHex.set("#7AB8FF")
            tintOpacity.set(0.08)
            blurOpacity.set(0.90)
            cornerRadius.set(0)
        case .nativeSidebar:
            matchTerminal.set(false)
            material.set(.sidebar)
            blendMode.set(.withinWindow)
            state.set(.followWindow)
            tintHex.set("#000000")
            tintOpacity.set(0.18)
            blurOpacity.set(1)
            cornerRadius.set(0)
        case .nativeTitlebar:
            matchTerminal.set(false)
            material.set(.titlebar)
            blendMode.set(.withinWindow)
            state.set(.followWindow)
            tintHex.set("#000000")
            tintOpacity.set(0.08)
            blurOpacity.set(1)
            cornerRadius.set(0)
        case .translucent:
            matchTerminal.set(false)
            material.set(.underWindowBackground)
            blendMode.set(.behindWindow)
            state.set(.active)
            tintHex.set("#000000")
            tintOpacity.set(0.20)
            blurOpacity.set(0.85)
            cornerRadius.set(0)
        case .opaqueDark:
            matchTerminal.set(false)
            material.set(.none)
            blendMode.set(.withinWindow)
            state.set(.active)
            tintHex.set("#171717")
            tintOpacity.set(1)
            blurOpacity.set(0)
            cornerRadius.set(0)
        case .opaqueLight:
            matchTerminal.set(false)
            material.set(.none)
            blendMode.set(.withinWindow)
            state.set(.active)
            tintHex.set("#F2F2F2")
            tintOpacity.set(1)
            blurOpacity.set(0)
            cornerRadius.set(0)
        case .custom:
            break
        }
    }

    @ViewBuilder
    private func pickerRow<Value: Hashable>(
        title: String,
        json: String,
        value: Value,
        options: [Value],
        label: @escaping (Value) -> String,
        set: @escaping (Value) -> Void
    ) -> some View {
        SettingsCardRow(configurationReview: .json(json), title) {
            Picker("", selection: Binding(get: { value }, set: set)) {
                ForEach(options, id: \.self) { option in Text(label(option)).tag(option) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 210)
        }
    }

    @ViewBuilder
    private func sliderRow<F: FormatStyle>(
        title: String,
        json: String,
        value: Double,
        range: ClosedRange<Double>,
        format: F,
        set: @escaping (Double) -> Void
    ) -> some View where F.FormatInput == Double, F.FormatOutput == String {
        SettingsCardRow(configurationReview: .json(json), title) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { value }, set: set), in: range)
                    .frame(width: 150)
                Text(value, format: format)
                    .font(.caption.monospacedDigit())
                    .frame(width: 54, alignment: .trailing)
            }
        }
    }

    private func presetTitle(_ option: SidebarPresetOption) -> String {
        switch option {
        case .liquidGlassSidebars: String(localized: "settings.sidebarAppearance.preset.liquidGlassSidebars", defaultValue: "Liquid Glass Sidebars")
        case .nativeSidebar: String(localized: "settings.sidebarAppearance.preset.nativeSidebar", defaultValue: "Native Sidebar")
        case .nativeTitlebar: String(localized: "settings.sidebarAppearance.preset.nativeTitlebar", defaultValue: "Native Titlebar")
        case .translucent: String(localized: "settings.sidebarAppearance.preset.translucent", defaultValue: "Translucent")
        case .opaqueDark: String(localized: "settings.sidebarAppearance.preset.opaqueDark", defaultValue: "Opaque Dark")
        case .opaqueLight: String(localized: "settings.sidebarAppearance.preset.opaqueLight", defaultValue: "Opaque Light")
        case .custom: String(localized: "settings.sidebarAppearance.preset.custom", defaultValue: "Custom")
        }
    }

    private func materialTitle(_ option: SidebarMaterialOption) -> String {
        switch option {
        case .none: String(localized: "settings.material.none", defaultValue: "None")
        case .liquidGlass: String(localized: "settings.material.liquidGlass", defaultValue: "Liquid Glass (macOS 26+)")
        default: option.rawValue.replacingOccurrences(of: "Background", with: " Background").capitalized
        }
    }

    private func blendModeTitle(_ option: SidebarBlendModeOption) -> String {
        option == .withinWindow
            ? String(localized: "settings.sidebarAppearance.blendMode.withinWindow", defaultValue: "Within Window")
            : String(localized: "settings.sidebarAppearance.blendMode.behindWindow", defaultValue: "Behind Window")
    }

    private func stateTitle(_ option: SidebarStateOption) -> String {
        switch option {
        case .active: String(localized: "settings.sidebarAppearance.state.active", defaultValue: "Always Active")
        case .inactive: String(localized: "settings.sidebarAppearance.state.inactive", defaultValue: "Always Inactive")
        case .followWindow: String(localized: "settings.sidebarAppearance.state.followWindow", defaultValue: "Follow Window")
        }
    }
}
