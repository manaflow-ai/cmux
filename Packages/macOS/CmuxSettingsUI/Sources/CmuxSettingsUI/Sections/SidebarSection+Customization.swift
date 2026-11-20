import CmuxSettings
import SwiftUI

extension SidebarSection {
    /// The sidebar feel group: glass, reveal, motion, density, drag.
    @ViewBuilder
    var customizationRows: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.sidebar.liquidGlass", defaultValue: "Liquid Glass"),
            subtitle: String(localized: "settings.sidebar.liquidGlass.subtitle", defaultValue: "Blur what is behind the window through the sidebar.")
        ) {
            Toggle("", isOn: Binding(get: { liquidGlass.current }, set: { liquidGlass.set($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .settingsSearchAnchors(["setting:sidebarAppearance:sidebar-liquid-glass"])
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.sidebar.blurOpacity", defaultValue: "Blur Opacity"),
            subtitle: String(localized: "settings.sidebar.blurOpacity.subtitle", defaultValue: "How much the glass blurs what is behind the window. Lower is lighter; higher is frostier."),
            controlWidth: 250
        ) {
            HStack(spacing: 8) {
                // Shown as a percentage of the blur range: 0% is the lightest
                // blur (the floor), 100% the frostiest.
                let blurRadius = glassBlurDraft ?? glassBlur.current
                let floor = Self.glassBlurRange.lowerBound
                Slider(
                    value: Binding(
                        get: { blurRadius / floor },
                        set: { multiplier in
                            let radius = (multiplier * floor).rounded()
                            glassBlurDraft = radius
                            debounceGlassWrite("glassBlur") { glassBlur.set(radius) }
                        }
                    ),
                    in: 1.0...(Self.glassBlurRange.upperBound / floor),
                    onEditingChanged: { editing in
                        guard !editing, let draft = glassBlurDraft else { return }
                        glassBlurDraft = nil
                        flushGlassWrite("glassBlur") { glassBlur.set(draft) }
                    }
                )
                .frame(width: 130)
                .accessibilityIdentifier("SettingsSidebarGlassBlurSlider")

                Text("\(Int(((blurRadius - floor) / (Self.glassBlurRange.upperBound - floor) * 100).rounded()))%")
                    .cmuxFont(size: 12, weight: .medium, design: .rounded)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)

                Button(String(localized: "settings.sidebar.glassBlur.reset", defaultValue: "Reset")) {
                    glassBlurDraft = nil
                    glassBlur.set(floor)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(abs(blurRadius - floor) < 0.5)
            }
        }
        .disabled(!liquidGlass.current)
        .settingsSearchAnchors(["setting:sidebarAppearance:sidebar-glass-blur"])
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("sidebarAppearance.tintColor"),
            String(localized: "settings.sidebar.tintColor", defaultValue: "Tint Color"),
            subtitle: String(localized: "settings.sidebar.tintColor.subtitle", defaultValue: "The color laid over the glass.")
        ) {
            HStack(spacing: 8) {
                if glassTintHex.current != Self.defaultGlassTintHex {
                    Button(String(localized: "settings.sidebar.tintColor.reset", defaultValue: "Reset")) {
                        glassTintHex.reset()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                HexColorPicker(
                    storedHex: glassTintHex.current,
                    fallback: Color.gray,
                    reconcileRevision: glassTintHex.revision
                ) { hex in
                    glassTintHex.set(hex)
                }
                Text(glassTintHex.current)
                    .cmuxFont(size: 12, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
            }
        }
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("sidebarAppearance.tintOpacity"),
            String(localized: "settings.sidebar.tintOpacity", defaultValue: "Tint Opacity"),
            subtitle: String(localized: "settings.sidebar.tintOpacity.subtitle", defaultValue: "How strongly the tint color covers the glass, from clear glass to a solid panel."),
            controlWidth: 250
        ) {
            HStack(spacing: 8) {
                let tintValue = glassTintDraft ?? glassTint.current
                Slider(
                    value: Binding(
                        get: { tintValue },
                        // Continuous track (a stepped slider draws tick dots);
                        // store rounded so the percent label stays stable.
                        set: { newValue in
                            let rounded = (newValue * 100).rounded() / 100
                            glassTintDraft = rounded
                            debounceGlassWrite("glassTint") { glassTint.set(rounded) }
                        }
                    ),
                    in: 0.0...1.0,
                    onEditingChanged: { editing in
                        guard !editing, let draft = glassTintDraft else { return }
                        glassTintDraft = nil
                        flushGlassWrite("glassTint") { glassTint.set(draft) }
                    }
                )
                .frame(width: 130)
                .accessibilityIdentifier("SettingsSidebarGlassTintSlider")

                Text("\(Int((tintValue * 100).rounded()))%")
                    .cmuxFont(size: 12, weight: .medium, design: .rounded)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)

                Button(String(localized: "settings.sidebar.glassTint.reset", defaultValue: "Reset")) {
                    glassTintDraft = nil
                    glassTint.set(Self.defaultGlassTint)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(abs(tintValue - Self.defaultGlassTint) < 0.001)
            }
        }
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("sidebarAppearance.matchTerminalBackground"),
            String(localized: "settings.sidebarAppearance.matchTerminalBackground", defaultValue: "Match Terminal Background"),
            subtitle: String(localized: "settings.sidebarAppearance.matchTerminalBackground.subtitle", defaultValue: "Use the same background color and transparency as the terminal.")
        ) {
            Toggle("", isOn: Binding(get: { matchTerminal.current }, set: { matchTerminal.set($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        SettingsCardDivider()

        SidebarRowHoverSettingRow()
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.sidebar.peekReveal", defaultValue: "Sidebar Peek Reveal Speed"),
            subtitle: String(localized: "settings.sidebar.peekReveal.subtitle", defaultValue: "How eagerly the hidden sidebar peeks out when the pointer reaches the left edge or the sidebar button.")
        ) {
            Picker("", selection: Binding(
                get: { peekReveal.current },
                set: { peekReveal.set($0) }
            )) {
                ForEach(SidebarPeekRevealPreset.allCases, id: \.self) { preset in
                    Text(peekRevealLabel(preset)).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(peekDisabled.current)
        }
        .settingsSearchAnchors(["setting:sidebarAppearance:sidebar-peek-reveal"])
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.sidebar.peekDisabled", defaultValue: "Disable Sidebar Peek"),
            subtitle: peekDisabled.current
                ? String(localized: "settings.sidebar.peekDisabled.subtitleOn", defaultValue: "The hidden sidebar never peeks out; bring it back with the shortcut or the sidebar button.")
                : String(localized: "settings.sidebar.peekDisabled.subtitleOff", defaultValue: "The hidden sidebar peeks out when the pointer rests at the left edge.")
        ) {
            Toggle("", isOn: Binding(get: { peekDisabled.current }, set: { peekDisabled.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
        .settingsSearchAnchors(["setting:sidebarAppearance:sidebar-peek-disabled"])
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.sidebar.rowDensity", defaultValue: "Row Density"),
            subtitle: String(localized: "settings.sidebar.rowDensity.subtitle", defaultValue: "Vertical breathing room inside each workspace row.")
        ) {
            Picker("", selection: Binding(
                get: { rowDensity.current },
                set: { rowDensity.set($0) }
            )) {
                ForEach(SidebarRowDensity.allCases, id: \.self) { density in
                    Text(densityLabel(density)).tag(density)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .settingsSearchAnchors(["setting:sidebarAppearance:sidebar-row-density"])
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.sidebar.dragSwitchDisabled", defaultValue: "Disable Switch on Drag"),
            subtitle: dragSwitchDisabled.current
                ? String(localized: "settings.sidebar.dragSwitchDisabled.subtitleOn", defaultValue: "Dragging a workspace only reorders it; your current workspace stays selected.")
                : String(localized: "settings.sidebar.dragSwitchDisabled.subtitleOff", defaultValue: "Picking up a workspace you are not on switches to it, so the row in your hand is the one you are using.")
        ) {
            Toggle("", isOn: Binding(get: { dragSwitchDisabled.current }, set: { dragSwitchDisabled.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
        .settingsSearchAnchors(["setting:sidebarAppearance:sidebar-drag-switch"])
        SettingsCardDivider()
    }

    /// Compositor blur bounds in points; the floor is also the default.
    static let glassBlurRange = SidebarAppearanceCatalogSection.glassBlurRadiusRange

    /// Default tint strength, mirrored from the catalog key.
    static let defaultGlassTint = SidebarAppearanceCatalogSection().tintOpacity.defaultValue

    /// Default tint colour, mirrored from the catalog key.
    static let defaultGlassTintHex = SidebarAppearanceCatalogSection().tintColorHex.defaultValue

    /// Coalesces slider writes: each thumb movement replaces the pending
    /// write, so the stored value (and the window re-render it triggers)
    /// lands once the thumb pauses instead of on every pixel.
    private func debounceGlassWrite(_ key: String, _ write: @escaping @MainActor @Sendable () -> Void) {
        tasks.replaceOnMainActor(key) {
            guard (try? await Task.sleep(for: .milliseconds(45))) != nil else { return }
            write()
        }
    }

    /// Writes immediately, superseding any pending debounced write.
    private func flushGlassWrite(_ key: String, _ write: @escaping @MainActor @Sendable () -> Void) {
        tasks.replaceOnMainActor(key) { write() }
    }

    private func peekRevealLabel(_ preset: SidebarPeekRevealPreset) -> String {
        switch preset {
        case .instant:
            String(localized: "settings.sidebar.peekReveal.instant", defaultValue: "Instant")
        case .quick:
            String(localized: "settings.sidebar.peekReveal.quick", defaultValue: "Quick")
        case .relaxed:
            String(localized: "settings.sidebar.peekReveal.relaxed", defaultValue: "Relaxed")
        }
    }

    private func densityLabel(_ density: SidebarRowDensity) -> String {
        switch density {
        case .compact:
            String(localized: "settings.sidebar.rowDensity.compact", defaultValue: "Compact")
        case .cozy:
            String(localized: "settings.sidebar.rowDensity.cozy", defaultValue: "Cozy")
        case .spacious:
            String(localized: "settings.sidebar.rowDensity.spacious", defaultValue: "Spacious")
        }
    }
}

/// Settings > Sidebar > Row Hover (`sidebarRowHover`, UI-only, on by
/// default). Its own view so the key stays private to this file; the sidebar
/// rows read it from UserDefaults and follow it live.
private struct SidebarRowHoverSettingRow: View {
    @AppStorage("sidebarRowHover") private var rowHover = true

    var body: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.sidebar.rowHover", defaultValue: "Row Hover"),
            subtitle: String(localized: "settings.sidebar.rowHover.subtitle", defaultValue: "Highlight rows under the pointer.")
        ) {
            Toggle("", isOn: $rowHover)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .settingsSearchAnchors(["setting:sidebarAppearance:sidebar-row-hover"])
    }
}
