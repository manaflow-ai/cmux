import CmuxSettings
import SwiftUI

extension SidebarSection {
    /// The sidebar feel group: glass, reveal, motion, density, drag.
    @ViewBuilder
    var customizationRows: some View {
        SettingsCardRow(
            configurationReview: .json("sidebarAppearance.tintOpacity"),
            String(localized: "settings.sidebar.glassTint", defaultValue: "Sidebar Glass Tint"),
            subtitle: String(localized: "settings.sidebar.glassTint.subtitle", defaultValue: "How strongly the sidebar tints the glass behind it, docked or floating. Lower is clearer glass."),
            controlWidth: 250
        ) {
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { glassTint.current },
                        // Continuous track (a stepped slider draws tick dots);
                        // store rounded so the percent label stays stable.
                        set: { glassTint.set(($0 * 100).rounded() / 100) }
                    ),
                    in: 0.0...1.0
                )
                .frame(width: 130)
                .accessibilityIdentifier("SettingsSidebarGlassTintSlider")

                Text("\(Int((glassTint.current * 100).rounded()))%")
                    .cmuxFont(size: 12, weight: .medium, design: .rounded)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)

                Button(String(localized: "settings.sidebar.glassTint.reset", defaultValue: "Reset")) {
                    glassTint.set(0.18)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(abs(glassTint.current - 0.18) < 0.001)
            }
        }
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("sidebar.peekReveal"),
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
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("sidebar.peekDisabled"),
            String(localized: "settings.sidebar.peekDisabled", defaultValue: "Disable Sidebar Peek"),
            subtitle: peekDisabled.current
                ? String(localized: "settings.sidebar.peekDisabled.subtitleOn", defaultValue: "The hidden sidebar never peeks out; bring it back with the shortcut or the sidebar button.")
                : String(localized: "settings.sidebar.peekDisabled.subtitleOff", defaultValue: "The hidden sidebar peeks out when the pointer rests at the left edge.")
        ) {
            Toggle("", isOn: Binding(get: { peekDisabled.current }, set: { peekDisabled.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("sidebar.rowDensity"),
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
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("sidebar.dragSwitchDisabled"),
            String(localized: "settings.sidebar.dragSwitchDisabled", defaultValue: "Disable Switch on Drag"),
            subtitle: dragSwitchDisabled.current
                ? String(localized: "settings.sidebar.dragSwitchDisabled.subtitleOn", defaultValue: "Dragging a workspace only reorders it; your current workspace stays selected.")
                : String(localized: "settings.sidebar.dragSwitchDisabled.subtitleOff", defaultValue: "Picking up a workspace you are not on switches to it, so the row in your hand is the one you are using.")
        ) {
            Toggle("", isOn: Binding(get: { dragSwitchDisabled.current }, set: { dragSwitchDisabled.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
        SettingsCardDivider()
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
